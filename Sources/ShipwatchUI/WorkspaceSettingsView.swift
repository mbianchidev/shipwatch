import AppKit
import ShipwatchCore
import SwiftUI

struct WorkspaceSettingsView: View {
    let model: AppModel
    @State private var excludedSelection = Set<String>()
    @State private var isTrackingFound = false
    @State private var isShowingIgnored = false
    @State private var cloneQuery = ""
    @State private var pendingRemoval: PendingRemoval?
    @FocusState private var cloneSearchFocused: Bool

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
                if !workspace.scan.clones.isEmpty {
                    SheetField(prompt: "Search clones by repository or path", text: $cloneQuery, symbol: "magnifyingglass", focused: $cloneSearchFocused, clearable: true)
                        .padding(.bottom, 8)
                }
                clonesTable
                if !workspace.untracked.isEmpty {
                    untrackedRow.padding(.top, 8)
                }
                if !prefs.ignoredRepos.isEmpty {
                    ignoredRow.padding(.top, 8)
                }
                actions.padding(.top, 14)
            }
        }
        .sheet(isPresented: $isTrackingFound) {
            TrackFoundRepositoriesSheet(model: model, clones: workspace.untracked) { isTrackingFound = false }
        }
        .sheet(isPresented: $isShowingIgnored) {
            IgnoredRepositoriesSheet(model: model) { isShowingIgnored = false }
        }
        .confirmsRemoval($pendingRemoval, model: model)
    }

    // MARK: Form

    private var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
            FormRow("Workspace folder:") {
                HStack(spacing: 8) {
                    folderField
                    if workspace.root == nil {
                        Button("Choose…", action: chooseWorkspace).keyboardShortcut(.defaultAction).fixedSize()
                    } else {
                        Button("Change…", action: chooseWorkspace).fixedSize()
                    }
                }
                FormCaption(
                    workspace.root == nil
                        ? "The folder where you keep your clones, for example ~/Developer."
                        : "Scanned up to \(WorkspaceScanner.maxDepth) levels deep. Hidden folders and node_modules are always skipped."
                )
            }

            FormRow("Keep default branches up to date:", dimmed: !switchEnabled) {
                Toggle(
                    "Keep default branches up to date",
                    isOn: Binding(get: { prefs.syncClones && switchEnabled }, set: { model.setSyncClones($0) })
                )
                .labelsHidden()
                .toggleStyle(.blueSwitch)
                .disabled(!switchEnabled)
                if !workspace.gitAvailable {
                    FormCaption("Needs git. Install the Command Line Tools with xcode-select --install, then restart Shipwatch.", color: Theme.warning)
                } else if workspace.root == nil {
                    FormCaption("Choose a workspace folder first.")
                } else {
                    FormCaption("Runs after every refresh, only when GitHub has new commits.")
                }
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
                    Text(
                        workspace.untracked.isEmpty
                            ? "No folder here has a git remote pointing at a repository you track."
                            : "None of the GitHub clones here belong to a repository you track yet."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                let clones = shownClones
                // Sized for every clone, so typing in the search doesn't resize the window.
                let height = CloneRow.height * CGFloat(min(workspace.scan.clones.count, 6))
                if clones.isEmpty {
                    Text("No clone matches “\(cloneQuery.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(height, 80))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(clones.enumerated()), id: \.element.id) { index, clone in
                                CloneRow(model: model, clone: clone) {
                                    pendingRemoval = PendingRemoval(repos: [clone.ref.key])
                                }
                                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.03))
                            }
                        }
                    }
                    .frame(height: height)
                }
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

    private var shownClones: [LocalClone] {
        let search = SearchText(cloneQuery)
        return workspace.scan.clones.filter { search.matches($0.ref.fullName, Self.abbreviated($0.path.path)) }
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

    private var untrackedRow: some View {
        let count = workspace.untracked.count
        return HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(count.counted("repository", "repositories")) cloned here \(count == 1 ? "isn't" : "aren't") tracked yet.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Track \(count) Found Here…") { isTrackingFound = true }
                .help("Choose which of these repositories Shipwatch shows and keeps up to date")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 4)
    }

    private var ignoredRow: some View {
        let count = prefs.ignoredRepos.count
        return HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(count.counted("ignored repository", "ignored repositories")) \(count == 1 ? "isn't" : "aren't") offered for tracking.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Show Ignored…") { isShowingIgnored = true }
                .help("List the ignored repositories and offer them for tracking again")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 4)
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

/// Picks which untracked github.com repositories found in the workspace to track, or to ignore so they aren't offered
/// again. All are selected at first. The buttons act only on the selected repositories the filter shows.
package struct TrackFoundRepositoriesSheet: View {
    let model: AppModel
    let clones: [LocalClone]
    let dismiss: () -> Void
    @State private var selected: Set<String>
    @State private var query = ""
    @FocusState private var filterFocused: Bool

    package init(model: AppModel, clones: [LocalClone], dismiss: @escaping () -> Void) {
        self.model = model
        self.clones = clones
        self.dismiss = dismiss
        _selected = State(initialValue: Set(clones.map(\.ref.key)))
    }

    /// Leaves out repositories ignored while the sheet is open.
    private var shown: [LocalClone] {
        let ignored = Set(model.workspace.ignored.map(\.key))
        let search = SearchText(query)
        return clones.filter {
            !ignored.contains($0.ref.key) && search.matches($0.ref.fullName, WorkspaceSettingsView.abbreviated($0.path.path))
        }
    }

    private var selectedRefs: [RepoRef] {
        shown.map(\.ref).filter { selected.contains($0.key) }
    }

    package var body: some View {
        let shown = shown
        let count = selectedRefs.count
        let allShownSelected = !shown.isEmpty && count == shown.count
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Track Repositories Found Here")
                    .font(.system(size: 15, weight: .semibold))
                Text("GitHub repositories cloned in your workspace that Shipwatch doesn't track yet. Ignore the ones you never want offered here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SheetField(prompt: "Filter repositories", text: $query, symbol: "magnifyingglass", focused: $filterFocused, clearable: true)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { clone in
                        let key = clone.ref.key
                        PickerRow(
                            name: AttributedString(clone.ref.fullName),
                            detail: Text(WorkspaceSettingsView.abbreviated(clone.path.path)),
                            isAdded: false,
                            isSelected: selected.contains(key)
                        ) { toggle(key) }
                    }
                    if shown.isEmpty {
                        Text(query.isEmpty ? "Nothing left to track here." : "No matches.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                }
            }
            .frame(height: 290)
            .settingsTable()

            HStack {
                Button(allShownSelected ? "Select None" : "Select All") {
                    let keys = shown.map(\.ref.key)
                    if allShownSelected { selected.subtract(keys) } else { selected.formUnion(keys) }
                }
                .disabled(shown.isEmpty)
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(count == 0 ? "Ignore" : "Ignore \(count)") { model.workspace.ignore(selectedRefs) }
                    .disabled(count == 0)
                    .help("Stop offering the selected repositories here. Settings > Workspace lists them under ignored repositories.")
                Button(count == 0 ? "Track Repositories" : "Track \(count.counted("Repository", "Repositories"))") {
                    model.addRepositories(selectedRefs)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
            }
            .controlSize(.large)
            .font(.system(size: 13))
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.settingsContent)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    private func toggle(_ key: String) {
        if selected.contains(key) {
            selected.remove(key)
        } else {
            selected.insert(key)
        }
    }
}

/// The repositories "Track N Found Here" doesn't offer, to offer them again.
package struct IgnoredRepositoriesSheet: View {
    let model: AppModel
    let dismiss: () -> Void
    @State private var selected = Set<String>()
    @State private var query = ""
    @FocusState private var filterFocused: Bool

    package init(model: AppModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
    }

    private var shown: [RepoRef] {
        let search = SearchText(query)
        return model.workspace.ignored.filter { search.matches($0.fullName) }
    }

    package var body: some View {
        let shown = shown
        let refs = shown.filter { selected.contains($0.key) }
        let allShownSelected = !shown.isEmpty && refs.count == shown.count
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ignored Repositories")
                    .font(.system(size: 15, weight: .semibold))
                Text("Track Found Here doesn't offer these. Stop ignoring them to see them there again.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            SheetField(prompt: "Filter repositories", text: $query, symbol: "magnifyingglass", focused: $filterFocused, clearable: true)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.key) { ref in
                        PickerRow(
                            name: AttributedString(ref.fullName),
                            detail: detail(ref),
                            isAdded: false,
                            isSelected: selected.contains(ref.key)
                        ) { toggle(ref.key) }
                    }
                    if shown.isEmpty {
                        Text(query.isEmpty ? "No ignored repositories." : "No matches.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                }
            }
            .frame(height: 290)
            .settingsTable()

            HStack {
                Button(allShownSelected ? "Select None" : "Select All") {
                    let keys = shown.map(\.key)
                    if allShownSelected { selected.subtract(keys) } else { selected.formUnion(keys) }
                }
                .disabled(shown.isEmpty)
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(refs.isEmpty ? "Stop Ignoring" : "Stop Ignoring \(refs.count)") {
                    model.workspace.stopIgnoring(refs)
                    selected.subtract(refs.map(\.key))
                    if model.workspace.ignored.isEmpty { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(refs.isEmpty)
            }
            .controlSize(.large)
            .font(.system(size: 13))
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.settingsContent)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    private func detail(_ ref: RepoRef) -> Text {
        guard let clone = model.workspace.untrackedClone(of: ref) else { return Text("Not in the workspace") }
        return Text(WorkspaceSettingsView.abbreviated(clone.path.path))
    }

    private func toggle(_ key: String) {
        if selected.contains(key) {
            selected.remove(key)
        } else {
            selected.insert(key)
        }
    }
}

private struct CloneRow: View {
    static let height: CGFloat = 40
    static let syncWidth: CGFloat = 46
    static let statusWidth: CGFloat = 210
    let model: AppModel
    let clone: LocalClone
    /// Asks to stop tracking the clone's repository.
    let remove: () -> Void

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
            .toggleStyle(.blueCheckbox)
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
            Divider()
            Button("Remove “\(clone.ref.name)” from Shipwatch…", role: .destructive, action: remove)
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
