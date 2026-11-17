import Foundation
import Observation
import ShipwatchCore
import ShipwatchUpdate

/// Why the last count of a repository didn't work, until one does.
public struct LineCountFailure: Equatable, Sendable {
    public var message: String
    public var date: Date

    public init(message: String, date: Date) {
        self.message = message
        self.date = date
    }
}

/// Counts the lines on the local default branch of each tracked repository's clone once a week, and keeps that
/// count and the one of the week before. The first count of a repository is its baseline.
@MainActor
@Observable
public final class LineCountModel {
    /// A count that failed isn't tried again sooner than this.
    public static let failureRetryInterval: TimeInterval = 15 * 60

    /// Keyed by `RepoRef.key`.
    public var reports: [String: LineCountReport] = [:]
    /// Keyed by `RepoRef.key`.
    public var failures: [String: LineCountFailure] = [:]

    @ObservationIgnored private let git: (any GitRunning)?
    @ObservationIgnored private let cache: LineCountCache?
    @ObservationIgnored private var isCounting = false

    public init(git: (any GitRunning)?, cache: LineCountCache?) {
        self.git = git
        self.cache = cache
        load()
    }

    /// Counts the repositories without a count this week, one at a time and off the main actor. `branches` holds
    /// the default branch GitHub reported per `RepoRef.key`; `main` otherwise. Reports of repositories that aren't
    /// in `tracked` are dropped. A pass that starts while another runs does nothing: the next refresh picks it up.
    func countDue(_ clones: [LocalClone], branches: [String: String], tracked: Set<String>, now: Date = Date()) async {
        guard let git, !isCounting else { return }
        isCounting = true
        defer { isCounting = false }
        forget(Set(reports.keys).subtracting(tracked))

        let counter = LineCounter(git: git)
        let byRepo = Dictionary(grouping: clones.filter { tracked.contains($0.ref.key) }, by: \.ref.key)
        for (key, repoClones) in byRepo.sorted(by: { $0.key < $1.key }) {
            if let report = reports[key], !report.isDue(at: now) { continue }
            if let failure = failures[key], now.timeIntervalSince(failure.date) < Self.failureRetryInterval { continue }
            let branch = branches[key] ?? "main"
            let result = await Task.detached(priority: .utility) {
                Self.count(repoClones, branch: branch, date: now, counter: counter)
            }.value
            record(result, for: key, branch: branch, now: now)
        }
    }

    /// The first clone (by path) that has the branch.
    nonisolated private static func count(
        _ clones: [LocalClone], branch: String, date: Date, counter: LineCounter
    ) -> Result<LineCount?, any Error> {
        var lastError: (any Error)?
        for clone in clones {
            do {
                if let count = try counter.count(clone, branch: branch, date: date) { return .success(count) }
            } catch {
                workspaceLog.error(
                    "Could not count lines in \(clone.path.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                lastError = error
            }
        }
        return lastError.map { .failure($0) } ?? .success(nil)
    }

    private func record(_ result: Result<LineCount?, any Error>, for key: String, branch: String, now: Date) {
        switch result {
        case .success(let count?):
            let report = reports[key].map { $0.adding(count) } ?? LineCountReport(latest: count)
            reports[key] = report
            failures[key] = nil
            let counts = count.counts
            workspaceLog.info(
                "Counted \(branch, privacy: .public) of \(key, privacy: .private) at \(count.commit.prefix(12), privacy: .public): \(counts.code) code, \(counts.tests) tests, \(counts.markdown) Markdown\(report.previous == nil ? " (baseline)" : "", privacy: .public)"
            )
            save()
        case .success(nil):
            if failures[key] == nil {
                workspaceLog.notice("No local \(branch, privacy: .public) branch to count lines of \(key, privacy: .private)")
            }
            failures[key] = LineCountFailure(message: "no local \(branch) branch", date: now)
        case .failure(let error):
            failures[key] = LineCountFailure(message: error.localizedDescription, date: now)
        }
    }

    /// Removed repositories start over from a new baseline if they are tracked again.
    func forget(_ ids: some Collection<String>) {
        guard !ids.isEmpty else { return }
        let before = reports.count
        for id in ids {
            reports[id] = nil
            failures[id] = nil
        }
        if reports.count != before { save() }
    }

    /// Keeps the counts of a repository GitHub now reports under another name.
    func rename(_ old: String, to new: String) {
        guard old != new, let report = reports.removeValue(forKey: old) else { return }
        reports[new] = report
        failures[old] = nil
        save()
    }

    private func load() {
        guard let cache else { return }
        do {
            reports = try cache.load()?.reports ?? [:]
        } catch {
            workspaceLog.error("Saved line counts are unreadable, counting again: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        guard let cache else { return }
        do {
            try cache.save(LineCountSnapshot(reports: reports))
        } catch {
            workspaceLog.error("Line counts could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension LineCountCache {
    /// `LineCounts.json` next to the status cache in `~/Library/Application Support/Shipwatch`.
    public static var standard: LineCountCache {
        LineCountCache(url: ShipwatchBundle.supportDirectory.appendingPathComponent("LineCounts.json"))
    }
}
