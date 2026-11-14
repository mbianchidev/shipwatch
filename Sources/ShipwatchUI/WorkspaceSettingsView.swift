import AppKit
import ShipwatchCore
import SwiftUI

struct WorkspaceSettingsView: View {
    let model: AppModel
    @State private var excludedSelection = Set<String>()

    private var workspace: WorkspaceModel { model.workspace }
    private var prefs: Preferences { model.prefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if workspace.root == nil {
                Text("Keep the default branch of your local clones in step with GitHub. Fast-forward only: Shipwatch never creates commits, resets, stashes, or switches branches.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)
            }
            form
            if workspace.root == nil {
                emptyState.padding(.top, 18)
            } else {
                SectionLabel("Excluded folders").padding(.leading, 4).padding(.top, 18).padding(.bottom, 6)
                excludedTable
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("Local clones")
                    Spacer()
                    if let scannedAt = workspace.scannedAt {
                        Text("scanned \(scannedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 18)
                .padding(.bottom, 6)
                clonesTable
                actions.padding(.top, 14)
            }
        }
    }

    // MARK: Form

    private var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                formLabel("Workspace folder:")
                HStack(spacing: 8) {
                    folderField
                    if workspace.root == nil {
                        Button("Choose…", action: chooseWorkspace).keyboardShortcut(.defaultAction).fixedSize()
                    } else {
                        Button("Change…", action: chooseWorkspace).fixedSize()
                    }
                }
            }
            formCaption(
                workspace.root == nil
                    ? "The folder where you keep your clones, for example ~/Developer."
                    : "Scanned up to \(WorkspaceScanner.maxDepth) levels deep. Hidden folders and node_modules are always skipped."
            )

            GridRow {
                formLabel("Keep default branches up to date:")
                    .foregroundStyle(switchEnabled ? .primary : .tertiary)
                Toggle(
                    "Keep default branches up to date",
                    isOn: Binding(get: { prefs.syncClones && switchEnabled }, set: { model.setSyncClones($0) })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!switchEnabled)
            }
            .padding(.top, 8)
            if !workspace.gitAvailable {
                formCaption("Needs git. Install the Command Line Tools with xcode-select --install, then restart Shipwatch.", color: Theme.warning)
            } else if workspace.root == nil {
                formCaption("Choose a workspace folder first.")
            } else {
                formCaption("Runs after every refresh, only when GitHub has new commits.")
            }
        }
    }

    private var switchEnabled: Bool { workspace.root != nil && workspace.gitAvailable }

    @ViewBuilder
    private var folderField: some View {
        HStack(spacing: 6) {
            if let root = workspace.root {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(Self.abbreviated(root.path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(root.path)
            } else {
                Text("No folder selected").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: 160, maxWidth: 320, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No workspace selected")
                .font(.system(size: 13, weight: .medium))
            Text("Shipwatch only looks inside the folder you choose, for clones of the repositories you track. Nothing on disk changes until you turn the switch on.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .settingsTable()
    }

    // MARK: Excluded folders

    private static let excludedRowHeight: CGFloat = 26

    private var excludedTable: some View {
        VStack(spacing: 0) {
            if prefs.excludedFolders.isEmpty {
                Text("No excluded folders")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: Self.excludedRowHeight)
            } else {
                List(selection: $excludedSelection) {
                    ForEach(prefs.excludedFolders, id: \.self) { path in
                        HStack(spacing: 7) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(Self.abbreviated(path)).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: 12.5))
                        .help(path)
                        .tag(path)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, Self.excludedRowHeight)
                .frame(height: Self.excludedRowHeight * CGFloat(min(prefs.excludedFolders.count, 4)) + 4)
                .onDeleteCommand(perform: removeExcluded)
            }
            Divider()
            HStack(spacing: 0) {
                Button(action: addExcluded) {
                    Image(systemName: "plus").frame(width: 30, height: 24)
                }
                .help("Exclude folders from the scan")
                Divider().frame(height: 24)
                Button(action: removeExcluded) {
                    Image(systemName: "minus").frame(width: 30, height: 24)
                }
                .disabled(excludedSelection.isEmpty)
                .help("Scan the selected folders again")
                Divider().frame(height: 24)
                Spacer()
                Text("Not scanned, including subfolders")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
        }
        .settingsTable()
    }

    // MARK: Local clones

    private var clonesTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Sync").frame(width: CloneRow.syncWidth, alignment: .leading)
                Text("Repository · local path")
                Spacer()
                Text("Default branch").frame(width: CloneRow.statusWidth, alignment: .leading)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.03))
            Divider()
            if workspace.scannedAt == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").foregroundStyle(.secondary)
                }
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, minHeight: 80)
            } else if workspace.scan.clones.isEmpty {
                VStack(spacing: 4) {
                    Text("No clones found")
                        .font(.system(size: 13, weight: .medium))
                    Text("No folder here has a git remote pointing at a repository you track.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(workspace.scan.clones.enumerated()), id: \.element.id) { index, clone in
                            CloneRow(model: model, clone: clone)
                                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.03))
                        }
                    }
                }
                .frame(height: CloneRow.height * CGFloat(min(workspace.scan.clones.count, 6)))
            }
            Divider()
            HStack {
                Spacer()
                Text(clonesSummary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
        }
        .settingsTable()
    }

    private var clonesSummary: String {
        let clones = workspace.scan.clones
        var parts = ["\(clones.count.counted("clone")) of \(Set(clones.map(\.ref.key)).count.counted("repository", "repositories"))"]
        let uncloned = workspace.uncloned
        if uncloned > 0 {
            parts.append("\(uncloned.counted("tracked repository", "tracked repositories")) not cloned here")
        }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if workspace.isSyncing {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            } else {
                Text(syncLine)
            }
            Spacer()
            Button("Rescan") { Task { await workspace.rescan() } }
            Button(action: model.syncAllClones) {
                Label("Sync Now", systemImage: "arrow.triangle.pull")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!workspace.canSync || workspace.isSyncing)
            .help(prefs.syncClones ? "Fetch and fast-forward every clone now" : "Turn the switch on first")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }

    private var syncLine: String {
        if let summary = workspace.lastSync { return summary.text }
        return prefs.syncClones ? "Not synced yet" : "Nothing on disk changes until you turn the switch on."
    }

    // MARK: Helpers

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseWorkspace() {
        let picked = Self.pickFolders(
            message: "Choose the folder where you keep your clones.",
            prompt: "Use as Workspace",
            multiple: false,
            startingAt: workspace.root
        )
        if let url = picked.first { workspace.setWorkspace(url) }
    }

    private func addExcluded() {
        workspace.addExcluded(Self.pickFolders(
            message: "Choose folders Shipwatch should not scan.",
            prompt: "Exclude",
            multiple: true,
            startingAt: workspace.root
        ))
    }

    private func removeExcluded() {
        workspace.removeExcluded(excludedSelection)
        excludedSelection = []
    }

    private static func pickFolders(message: String, prompt: String, multiple: Bool, startingAt directory: URL?) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = !multiple
        panel.allowsMultipleSelection = multiple
        panel.directoryURL = directory
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls : []
    }
}

private struct CloneRow: View {
    static let height: CGFloat = 40
    static let syncWidth: CGFloat = 46
    static let statusWidth: CGFloat = 210
    let model: AppModel
    let clone: LocalClone

    private var workspace: WorkspaceModel { model.workspace }
    private var optedOut: Bool { workspace.isOptedOut(clone.ref) }
    private var defaultBranch: String? { model.statuses[clone.ref.key]?.defaultBranch }

    var body: some View {
        HStack(spacing: 0) {
            Toggle(
                "Sync \(clone.ref.key)",
                isOn: Binding(get: { !optedOut }, set: { model.setCloneSyncOptedOut(clone.ref, !$0) })
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: Self.syncWidth, alignment: .leading)
            .help(optedOut ? "Shipwatch leaves clones of \(clone.ref.key) alone" : "Keep clones of \(clone.ref.key) up to date")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(clone.ref.name).foregroundStyle(optedOut ? .secondary : .primary)
                    Text(clone.ref.owner).foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
                HStack(spacing: 6) {
                    Text(WorkspaceSettingsView.abbreviated(clone.path.path))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .help(clone.path.path)
                    if let checkedOut = checkedOutElsewhere {
                        RefTag(name: "on \(checkedOut)")
                    }
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            status.frame(width: Self.statusWidth, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .contextMenu {
            Button("Show in Finder") { model.actions.revealInFinder([clone.path]) }
        }
    }

    /// The branch checked out in this clone when it isn't the default branch.
    private var checkedOutElsewhere: String? {
        guard let defaultBranch else { return nil }
        let head = clone.headBranch ?? "detached HEAD"
        return head == defaultBranch ? nil : head
    }

    private var status: some View {
        let display = CloneStatusDisplay(
            optedOut: optedOut,
            syncing: workspace.syncingPaths.contains(clone.path),
            result: workspace.results[clone.path],
            defaultBranch: defaultBranch,
            remote: clone.remote,
            syncEnabled: model.prefs.syncClones
        )
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            let text = display.text(now: context.date)
            HStack(alignment: .center, spacing: 7) {
                CIIcon(glyph: display.glyph, size: 13)
                VStack(alignment: .leading, spacing: 1) {
                    Text(text.title).font(.system(size: 12.5))
                        .foregroundStyle(display.isWarning ? Theme.warning : .primary)
                    if let detail = text.detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .help(detail)
                    }
                }
                .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([text.title, text.detail].compactMap(\.self).joined(separator: ", "))
        }
    }
}

/// What the status column says about one clone.
struct CloneStatusDisplay {
    /// Fast-forwards stay visible this long after later passes found nothing new.
    static let recentUpdate: TimeInterval = 60 * 60

    var optedOut: Bool
    var syncing: Bool
    var result: CloneSyncResult?
    var defaultBranch: String?
    var remote: String
    var syncEnabled: Bool

    var glyph: CIGlyph {
        if optedOut { return .none }
        if syncing { return .running }
        switch result?.outcome {
        case .upToDate, .updated: return .passing
        case .skipped: return .noAccess
        case .failed: return .failing
        case nil: return .none
        }
    }

    var isWarning: Bool {
        if case .skipped = result?.outcome, !optedOut, !syncing { return true }
        return false
    }

    func text(now: Date) -> (title: String, detail: String?) {
        if optedOut { return ("Off for this repo", nil) }
        let branch = result?.branch ?? defaultBranch
        if syncing { return ("Updating…", branch) }
        guard let result else {
            return ("Not synced yet", syncEnabled ? branch : "the switch is off")
        }
        switch result.outcome {
        case .updated, .upToDate:
            if let ff = result.lastFastForward, now.timeIntervalSince(ff.date) < Self.recentUpdate {
                return ("Updated \(RelativeTime.updated(ff.date, now: now))", "\(result.branch) +\(ff.commits.counted("commit"))")
            }
            return ("Up to date", result.branch)
        case .skipped(let reason):
            return ("Skipped", reason.message(branch: result.branch, remote: remote))
        case .failed(let message):
            return ("Failed", message)
        }
    }
}
