import AppKit
import Observation
import ShipwatchCore
import os

let workspaceLog = Logger(subsystem: "dev.mbianchi.shipwatch", category: "workspace")

/// The last fast-forward Shipwatch made in a clone.
public struct FastForward: Equatable, Sendable {
    public var date: Date
    public var commits: Int

    public init(date: Date, commits: Int) {
        self.date = date
        self.commits = commits
    }
}

/// What happened the last time Shipwatch looked at a clone.
public struct CloneSyncResult: Equatable, Sendable {
    public var outcome: CloneSyncOutcome
    public var branch: String
    public var remoteHead: String
    public var date: Date
    /// Kept across later "up to date" passes so the row can say "Updated 3 min ago".
    public var lastFastForward: FastForward?

    public init(outcome: CloneSyncOutcome, branch: String, remoteHead: String, date: Date, lastFastForward: FastForward? = nil) {
        self.outcome = outcome
        self.branch = branch
        self.remoteHead = remoteHead
        self.date = date
        self.lastFastForward = lastFastForward
    }

    public var needsAttention: Bool {
        switch outcome {
        case .skipped, .failed: true
        case .upToDate, .updated: false
        }
    }
}

public struct WorkspaceSyncSummary: Equatable, Sendable {
    public var date: Date
    public var updated = 0
    public var skipped = 0
    public var failed = 0

    public init(date: Date, updated: Int = 0, skipped: Int = 0, failed: Int = 0) {
        self.date = date
        self.updated = updated
        self.skipped = skipped
        self.failed = failed
    }

    /// `Last sync 15:40 · 1 updated · 2 skipped`, or `· all up to date` when nothing changed.
    public var text: String {
        var parts = ["Last sync \(date.formatted(date: .omitted, time: .shortened))"]
        if updated > 0 { parts.append("\(updated) updated") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        if parts.count == 1 { parts.append("all up to date") }
        return parts.joined(separator: " · ")
    }
}

/// Finds local clones of tracked repositories inside the workspace folder and fast-forwards their default branch.
@MainActor
@Observable
public final class WorkspaceModel {
    /// A failed fetch for the same GitHub head is not retried sooner than this, unless the user asks.
    public static let failureRetryInterval: TimeInterval = 15 * 60
    /// Refreshes run every 20 s while a workflow is running; the folder walk doesn't need to.
    public static let rescanInterval: TimeInterval = 5 * 60

    let prefs: Preferences
    public var scan = WorkspaceScan()
    public var scannedAt: Date?
    /// Keyed by clone path.
    public var results: [URL: CloneSyncResult] = [:]
    public var lastSync: WorkspaceSyncSummary?
    public var syncingPaths: Set<URL> = []
    public let gitAvailable: Bool

    @ObservationIgnored private let git: (any GitRunning)?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var scannedTracked: Set<String> = []

    public init(prefs: Preferences, git: (any GitRunning)? = ProcessGit.locate()) {
        self.prefs = prefs
        self.git = git
        gitAvailable = git != nil
        if git == nil { workspaceLog.notice("git not found, local clone updates are unavailable") }
    }

    // MARK: Derived state

    public var root: URL? {
        prefs.workspacePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public var isSyncing: Bool { !syncingPaths.isEmpty }

    public var canSync: Bool { root != nil && gitAvailable && prefs.syncClones }

    public func isOptedOut(_ ref: RepoRef) -> Bool {
        prefs.cloneSyncOptOut.contains(ref.key)
    }

    public func clones(of ref: RepoRef) -> [LocalClone] {
        scan.clones.filter { $0.ref.key == ref.key }
    }

    /// Clones whose last sync was skipped or failed, while syncing is on for them.
    public var attentionCount: Int {
        guard canSync else { return 0 }
        return scan.clones.filter { !isOptedOut($0.ref) && results[$0.path]?.needsAttention == true }.count
    }

    /// Tracked repositories with no clone in the workspace.
    public var uncloned: Int {
        let cloned = Set(scan.clones.map(\.ref.key))
        return prefs.repos.items.filter { !cloned.contains($0.id) }.count
    }

    // MARK: Settings

    public func setWorkspace(_ url: URL?) {
        let path = url.map { WorkspaceScanner.canonical($0).path }
        guard path != prefs.workspacePath else { return }
        prefs.workspacePath = path
        results = [:]
        lastSync = nil
        if path == nil {
            prefs.syncClones = false
        }
        workspaceLog.info("Workspace set to \(path ?? "none", privacy: .public)")
        Task { await rescan() }
    }

    public func addExcluded(_ urls: [URL]) {
        let paths = urls.map { WorkspaceScanner.canonical($0).path }.filter { !prefs.excludedFolders.contains($0) }
        guard !paths.isEmpty else { return }
        prefs.excludedFolders = (prefs.excludedFolders + paths).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        Task { await rescan() }
    }

    public func removeExcluded(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        prefs.excludedFolders.removeAll { paths.contains($0) }
        Task { await rescan() }
    }

    // MARK: Scan

    public func rescan() async {
        guard let root else {
            scan = WorkspaceScan()
            scannedAt = nil
            results = [:]
            return
        }
        let scanner = WorkspaceScanner(root: root, excluded: prefs.excludedFolders.map { URL(fileURLWithPath: $0, isDirectory: true) })
        let tracked = Set(prefs.repos.items.map(\.id))
        let found = await Task.detached(priority: .utility) { scanner.scan(tracked: tracked) }.value
        guard root == self.root else { return }
        scannedTracked = tracked
        for folder in found.unreadable {
            workspaceLog.error("Could not read \(folder.path, privacy: .public) while scanning the workspace")
        }
        if !FileManager.default.fileExists(atPath: root.path) {
            workspaceLog.error("Workspace folder \(root.path, privacy: .public) does not exist")
        }
        let paths = Set(found.clones.map(\.path))
        results = results.filter { paths.contains($0.key) }
        scan = found
        scannedAt = Date()
    }

    // MARK: Sync

    /// Called after every successful refresh: rescan when stale, then fast-forward clones whose GitHub head moved.
    func afterRefresh(statuses: [String: RepoStatus]) async {
        guard root != nil else { return }
        let stale = scannedAt.map { Date().timeIntervalSince($0) >= Self.rescanInterval } ?? true
        if stale || scannedTracked != Set(prefs.repos.items.map(\.id)) {
            await rescan()
        }
        guard canSync else { return }
        await sync(scan.clones, statuses: statuses, force: false)
    }

    /// The "Sync Now" button: every clone that isn't opted out, ignoring the failure back-off.
    public func syncAll(statuses: [String: RepoStatus]) {
        guard canSync else { return }
        Task {
            await rescan()
            await sync(scan.clones, statuses: statuses, force: true)
        }
    }

    /// "Update Local Clone Now" in the popover.
    public func sync(_ ref: RepoRef, statuses: [String: RepoStatus]) {
        guard canSync else { return }
        let clones = clones(of: ref)
        Task { await sync(clones, statuses: statuses, force: true) }
    }

    /// Passes run one after another, so two never touch the same clone at once.
    private func sync(_ clones: [LocalClone], statuses: [String: RepoStatus], force: Bool) async {
        guard let git else { return }
        let previous = syncTask
        let task = Task {
            await previous?.value
            await perform(clones, statuses: statuses, force: force, git: git)
        }
        syncTask = task
        await task.value
        if syncTask == task { syncTask = nil }
    }

    private func perform(_ clones: [LocalClone], statuses: [String: RepoStatus], force: Bool, git: any GitRunning) async {
        let syncer = CloneSyncer(git: git)
        var summary = WorkspaceSyncSummary(date: Date())
        var attempted = 0
        for clone in clones where !isOptedOut(clone.ref) && prefs.syncClones {
            guard let status = statuses[clone.ref.key], status.problem == nil,
                  let branch = status.defaultBranch, let head = status.defaultBranchHead
            else { continue }
            let previous = results[clone.path]
            if !force, let previous, !Self.shouldRetry(previous, remoteHead: head) {
                continue
            }
            attempted += 1
            syncingPaths.insert(clone.path)
            let outcome = await Task.detached(priority: .utility) {
                syncer.sync(clone, branch: branch, remoteHead: head)
            }.value
            syncingPaths.remove(clone.path)
            record(outcome, for: clone, branch: branch, head: head.lowercased(), previous: previous, into: &summary)
        }
        if attempted > 0 { lastSync = summary }
    }

    /// Without a new GitHub head there's nothing to fetch. Skipped clones are retried (the user may have
    /// committed or stashed), failures only after a back-off.
    static func shouldRetry(_ previous: CloneSyncResult, remoteHead: String, now: Date = Date()) -> Bool {
        guard previous.remoteHead == remoteHead.lowercased() else { return true }
        switch previous.outcome {
        case .upToDate, .updated: return false
        case .skipped: return true
        case .failed: return now.timeIntervalSince(previous.date) >= failureRetryInterval
        }
    }

    private func record(
        _ outcome: CloneSyncOutcome, for clone: LocalClone, branch: String, head: String, previous: CloneSyncResult?,
        into summary: inout WorkspaceSyncSummary
    ) {
        let now = Date()
        var lastFastForward = previous?.lastFastForward
        let path = clone.path.path
        switch outcome {
        case .updated(let commits):
            summary.updated += 1
            lastFastForward = FastForward(date: now, commits: commits)
            workspaceLog.info("Fast-forwarded \(branch, privacy: .public) in \(path, privacy: .public) by \(commits) commits")
        case .skipped(let reason):
            summary.skipped += 1
            if previous?.outcome != outcome {
                let message = reason.message(branch: branch, remote: clone.remote)
                workspaceLog.notice("Skipped \(path, privacy: .public): \(message, privacy: .public)")
            }
        case .failed(let message):
            summary.failed += 1
            workspaceLog.error("Could not update \(path, privacy: .public): \(message, privacy: .public)")
        case .upToDate:
            break
        }
        results[clone.path] = CloneSyncResult(outcome: outcome, branch: branch, remoteHead: head, date: now, lastFastForward: lastFastForward)
    }

    // MARK: Opt-out

    public func setOptedOut(_ ref: RepoRef, _ optedOut: Bool, statuses: [String: RepoStatus]) {
        if optedOut {
            prefs.cloneSyncOptOut.insert(ref.key)
        } else {
            prefs.cloneSyncOptOut.remove(ref.key)
            sync(ref, statuses: statuses)
        }
    }
}
