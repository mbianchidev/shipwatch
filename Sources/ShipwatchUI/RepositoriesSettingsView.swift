import ShipwatchCore
import SwiftUI

struct RepositoriesSettingsView: View {
    let model: AppModel
    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var pendingRemoval: PendingRemoval?
    @FocusState private var focusedGroup: RepoGroup.ID?
    @FocusState private var searchFocused: Bool
    private static let listRowInset: CGFloat = 8

    private var repos: RepoList { model.prefs.repos }
    private var search: SearchText { SearchText(query) }
    private var rows: [RepoListRow] { repos.rows(collapsing: model.collapsedSettingsGroups, matching: search) }
    /// Sized for the rows without the search, so typing doesn't resize the window.
    private var tableHeight: CGFloat {
        RepoSettingsRow.height * CGFloat(min(max(repos.rows(collapsing: model.collapsedSettingsGroups).count, 4), 11))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repositories shown in the menu, in this order. Drag to reorder, pick a group in the Group column, click the eye to hide or show, the bell for release notifications and the person to count only yours. Groups collapse into one row in the menu, and here with the arrow.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !repos.items.isEmpty || !repos.groups.isEmpty {
                SheetField(prompt: "Search repositories and groups", text: $query, symbol: "magnifyingglass", focused: $searchFocused, clearable: true)
            }

            VStack(spacing: 0) {
                header
                Divider()
                table
                Divider()
                footer
            }
            .settingsTable()
            .sheet(item: Binding(get: { model.groupEditor }, set: { model.groupEditor = $0 })) { editor in
                GroupEditorSheet(model: model, editor: editor) { selection = [RepoGroup.entryID($0)] }
            }
        }
        .sheet(isPresented: Binding(get: { model.isAddingRepositories }, set: { model.isAddingRepositories = $0 })) {
            AddRepositoriesSheet(model: model)
        }
        .confirmsRemoval($pendingRemoval, model: model)
    }

    @ViewBuilder
    private var table: some View {
        if repos.items.isEmpty && repos.groups.isEmpty {
            VStack(spacing: 6) {
                Text("No repositories yet")
                    .font(.system(size: 13, weight: .medium))
                Text("Click + to pick repositories your token can read.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else if rows.isEmpty {
            VStack(spacing: 6) {
                Text("No matches")
                    .font(.system(size: 13, weight: .medium))
                Text("No repository or group name contains “\(search.needle)”.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: tableHeight)
        } else {
            list
        }
    }

    private var list: some View {
        // Offsets of a filtered list don't map onto the whole one, so dragging waits for the search to clear.
        let reorder: ((IndexSet, Int) -> Void)? = search.isEmpty ? { move($0, $1) } : nil
        return List(selection: $selection) {
            ForEach(rows) { row in
                rowView(row)
                    .tag(row.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
            }
            .onMove(perform: reorder)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds()
        .environment(\.defaultMinListRowHeight, RepoSettingsRow.height)
        .frame(height: tableHeight)
        .onDeleteCommand(perform: removeSelection)
        // Rows a collapse or the search hides can't stay selected, or "-" would remove repositories you can't see.
        .onChange(of: rows.map(\.id)) { _, shown in selection.formIntersection(shown) }
    }

    @ViewBuilder
    private func rowView(_ row: RepoListRow) -> some View {
        switch row {
        case .group(let group):
            GroupSettingsRow(model: model, group: group, focus: $focusedGroup, isSearching: !search.isEmpty) {
                removeGroup(group.id)
            }
        case .repo(let repo):
            RepoSettingsRow(model: model, repo: repo, targets: { targets(for: repo) }) {
                pendingRemoval = PendingRemoval(repos: targets(for: repo))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 28)
            Text("Show").frame(width: RepoSettingsRow.showWidth, alignment: .leading)
            Text("Notify").frame(width: RepoSettingsRow.notifyWidth, alignment: .leading)
            Text("Mine").frame(width: RepoSettingsRow.mineWidth, alignment: .leading)
            Text("Repository")
            Spacer()
            Text("Group").frame(width: RepoSettingsRow.groupWidth, alignment: .leading)
            Text("Access").frame(width: RepoSettingsRow.accessWidth, alignment: .leading)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        // Matches the horizontal inset AppKit's table view gives each List row.
        .padding(.leading, Self.listRowInset)
        .padding(.trailing, 12 + Self.listRowInset)
        .background(Color.white.opacity(0.03))
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button { model.isAddingRepositories = true } label: {
                Image(systemName: "plus").frame(width: 30, height: 24)
            }
            .help("Add repositories")
            Divider().frame(height: 24)
            Button(action: removeSelection) {
                Image(systemName: "minus").frame(width: 30, height: 24)
            }
            .disabled(selection.isEmpty)
            .help("Remove the selected repositories from Shipwatch, or ungroup the selected groups. Nothing changes on GitHub.")
            Divider().frame(height: 24)
            Button { model.showGroupEditor(.new(selectedRepoIDs)) } label: {
                Label("New Group…", systemImage: "folder.badge.plus")
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
            }
            .help(selectedRepoIDs.isEmpty ? "Create a group and pick its repositories" : "Create a group with the selected repositories")
            Divider().frame(height: 24)
            Spacer()
            Text(repos.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.trailing, 12)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
    }

    private var selectedRepoIDs: [TrackedRepo.ID] {
        repos.items.map(\.id).filter(selection.contains)
    }

    /// A row's menus act on the whole selection when the row is part of it.
    private func targets(for repo: TrackedRepo) -> [TrackedRepo.ID] {
        selection.contains(repo.id) ? selectedRepoIDs : [repo.id]
    }

    private func removeGroup(_ id: RepoGroup.ID) {
        selection.remove(RepoGroup.entryID(id))
        model.removeGroup(id)
    }

    private func move(_ source: IndexSet, _ destination: Int) {
        model.prefs.repos.moveRows(fromOffsets: source, toOffset: destination, collapsing: model.collapsedSettingsGroups)
    }

    /// Ungroups the selected groups right away, but asks before removing repositories.
    private func removeSelection() {
        let groups = repos.groups.filter { selection.contains($0.entryID) }.map(\.id)
        let ids = selectedRepoIDs
        if ids.isEmpty {
            groups.forEach(removeGroup)
        } else {
            pendingRemoval = PendingRemoval(repos: ids, groups: groups)
        }
    }
}

extension RepoList {
    /// "45 repositories · 5 groups · 5 hidden".
    var summary: String {
        var parts = [items.count.counted("repository", "repositories")]
        if !groups.isEmpty { parts.append(groups.count.counted("group")) }
        parts.append("\(hiddenCount) hidden")
        return parts.joined(separator: " · ")
    }
}

/// Repositories waiting for the user to confirm they should leave Shipwatch.
struct PendingRemoval {
    var repos: [TrackedRepo.ID]
    /// Groups selected along with them, ungrouped once confirmed.
    var groups: [RepoGroup.ID] = []
}

extension View {
    /// Asks before removing repositories from Shipwatch, saying that GitHub and local clones stay as they are. With a
    /// workspace, it also offers to ignore them, so "Track N Found Here" doesn't offer them again.
    func confirmsRemoval(_ pending: Binding<PendingRemoval?>, model: AppModel) -> some View {
        let ids = pending.wrappedValue?.repos ?? []
        let title = if ids.count == 1, let repo = model.prefs.repos.items.first(where: { $0.id == ids[0] }) {
            "Remove “\(repo.ref.fullName)” from Shipwatch?"
        } else {
            "Remove \(ids.count.counted("repository", "repositories")) from Shipwatch?"
        }
        return confirmationDialog(
            title,
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { removal in
            Button("Remove", role: .destructive) {
                removal.groups.forEach(model.removeGroup)
                model.removeRepositories(removal.repos)
            }
            if model.workspace.root != nil {
                Button("Remove and Ignore", role: .destructive) {
                    removal.groups.forEach(model.removeGroup)
                    model.removeRepositories(removal.repos, ignoring: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            let pronoun = removal.repos.count == 1 ? "it" : "them"
            if model.workspace.root != nil {
                Text("Shipwatch stops showing \(pronoun). Nothing changes on GitHub, and local clones stay on disk. Remove and Ignore also stops offering \(pronoun) under Track Found Here in Workspace.")
            } else {
                Text("Shipwatch stops showing \(pronoun). Nothing changes on GitHub, and local clones stay on disk.")
            }
        }
    }
}

/// A group's header row: an arrow to collapse it, its name, editable in place, and how many repositories it holds.
struct GroupSettingsRow: View {
    let model: AppModel
    let group: RepoGroup
    var focus: FocusState<RepoGroup.ID?>.Binding
    /// Groups stay open while searching.
    var isSearching = false
    let ungroup: () -> Void

    private var isCollapsed: Bool { !isSearching && model.collapsedSettingsGroups.contains(group.id) }

    var body: some View {
        HStack(spacing: 0) {
            GripDots()
                .frame(width: 28)
                .help("Drag to move the group")
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 10)
                    Image(systemName: isCollapsed ? "folder" : "folder.fill")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 22, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSearching)
            .frame(width: 46, alignment: .leading)
            .help(isCollapsed ? "Show the group's repositories" : "Hide the group's repositories")
            .accessibilityLabel(isCollapsed ? "Expand \(group.displayName)" : "Collapse \(group.displayName)")
            TextField("Group name", text: Binding(get: { group.name }, set: { model.renameGroup(group.id, to: $0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .focused(focus, equals: group.id)
                .accessibilityLabel("Group name")
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Text(model.prefs.repos.members(of: group.id).count.counted("repository", "repositories"))
                    .foregroundStyle(.secondary)
                Group {
                    Button("Edit…") { model.showGroupEditor(.edit(group.id)) }
                        .help("Rename the group and pick its repositories")
                    Button("Ungroup", action: ungroup)
                        .help("Delete the group. Its repositories stay in Shipwatch.")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.link)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .frame(width: RepoSettingsRow.groupWidth + RepoSettingsRow.accessWidth, alignment: .leading)
        }
        .padding(.trailing, 12)
        .frame(height: RepoSettingsRow.height)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit…") { model.showGroupEditor(.edit(group.id)) }
            Button("Rename") { focus.wrappedValue = group.id }
            Divider()
            Button(isCollapsed ? "Expand" : "Collapse", action: toggle)
                .disabled(isSearching)
            Button("Collapse All Groups") { withAnimation(Self.animation) { model.setSettingsGroupsCollapsed(true) } }
            Button("Expand All Groups") { withAnimation(Self.animation) { model.setSettingsGroupsCollapsed(false) } }
            Divider()
            Button("Ungroup", action: ungroup)
        }
    }

    private static let animation = Animation.easeInOut(duration: 0.15)

    private func toggle() {
        withAnimation(Self.animation) { model.toggleSettingsGroup(group.id) }
    }
}

struct RepoSettingsRow: View {
    static let showWidth: CGFloat = 44
    static let notifyWidth: CGFloat = 48
    static let mineWidth: CGFloat = 44
    static let groupWidth: CGFloat = 120
    static let accessWidth: CGFloat = 140
    static let height: CGFloat = 32
    let model: AppModel
    let repo: TrackedRepo
    /// The repositories the row's menus act on.
    let targets: () -> [TrackedRepo.ID]
    /// Asks to remove `targets()` from Shipwatch.
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            GripDots()
                .frame(width: 28)
                .help("Drag to reorder")
            Button { model.setHidden(repo.id, !repo.hidden) } label: {
                Image(systemName: repo.hidden ? "eye.slash" : "eye")
                    .font(.system(size: 13))
                    .foregroundStyle(repo.hidden ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.link))
                    .frame(width: 30, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: Self.showWidth, alignment: .leading)
            .help(repo.hidden ? "Show in the menu" : "Hide from the menu")
            notifyButton
            mineButton
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(repo.ref.name)
                    .foregroundStyle(repo.hidden ? .secondary : .primary)
                    .layoutPriority(1)
                Text(repo.ref.owner)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.leading, repo.group == nil ? 0 : 18)
            Spacer(minLength: 8)
            groupMenu
                .frame(width: Self.groupWidth, alignment: .leading)
            access
                .frame(width: Self.accessWidth, alignment: .leading)
        }
        .padding(.trailing, 12)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .contextMenu {
            Menu("Move to Group") {
                ForEach(model.prefs.repos.groups) { group in
                    Button(group.displayName) { model.setGroup(targets(), to: group.id) }
                        .disabled(repo.group == group.id && targets().count == 1)
                }
                if !model.prefs.repos.groups.isEmpty { Divider() }
                Button("New Group…") { model.showGroupEditor(.new(targets())) }
            }
            if repo.group != nil {
                Button("Remove from Group") { model.setGroup(targets(), to: nil) }
            }
            Divider()
            let ids = targets()
            let notifying = ids.allSatisfy(model.notifiesReleases)
            Button(notifying ? "Stop Notifying About Releases" : "Notify About New Releases") {
                model.setReleaseNotifications(ids, !notifying)
            }
            if !model.prefs.onlyMine {
                let mine = ids.allSatisfy(model.isOnlyMine)
                Button(mine ? "Show Everyone's Issues, PRs and Runs" : "Show Only My Issues, PRs and Runs") {
                    model.setOnlyMine(ids, !mine)
                }
            }
            Divider()
            let count = ids.count
            Button(count == 1 ? "Remove from Shipwatch…" : "Remove \(count) Repositories from Shipwatch…", role: .destructive, action: remove)
        }
    }

    /// The bell: a notification when the repository publishes a GitHub release.
    private var notifyButton: some View {
        let on = model.notifiesReleases(of: repo.id)
        return Button { model.setReleaseNotifications([repo.id], !on) } label: {
            Image(systemName: on ? "bell.fill" : "bell")
                .font(.system(size: 13))
                .foregroundStyle(on ? AnyShapeStyle(Theme.link) : AnyShapeStyle(.tertiary))
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: Self.notifyWidth, alignment: .leading)
        .help(on ? "Stop notifying about new releases" : "Notify me when it publishes a GitHub release")
        .accessibilityLabel("Release notifications for \(repo.ref.fullName)")
        .accessibilityValue(on ? "On" : "Off")
    }

    /// The person: only issues and pull requests assigned to you, and workflow runs you triggered.
    private var mineButton: some View {
        let everywhere = model.prefs.onlyMine
        let on = model.isOnlyMine(repo.id)
        return Button { model.setOnlyMine([repo.id], !on) } label: {
            Image(systemName: on ? "person.fill" : "person")
                .font(.system(size: 13))
                .foregroundStyle(on && !everywhere ? AnyShapeStyle(Theme.link) : AnyShapeStyle(.tertiary))
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(everywhere)
        .frame(width: Self.mineWidth, alignment: .leading)
        .help(
            everywhere ? "On for every repository in Settings > General"
                : on ? "Show everyone's issues, pull requests and workflow runs"
                : "Show only issues and pull requests assigned to you, and workflow runs you triggered"
        )
        .accessibilityLabel("Only mine for \(repo.ref.fullName)")
        .accessibilityValue(on ? "On" : "Off")
    }

    private var groupMenu: some View {
        let current = repo.group.flatMap { model.prefs.repos.group($0) }
        return Menu {
            Picker("Group", selection: Binding(get: { repo.group }, set: { model.setGroup(targets(), to: $0) })) {
                Text("None").tag(RepoGroup.ID?.none)
                ForEach(model.prefs.repos.groups) { group in
                    Text(group.displayName).tag(RepoGroup.ID?.some(group.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("New Group…") { model.showGroupEditor(.new(targets())) }
        } label: {
            HStack(spacing: 4) {
                Text(current?.displayName ?? "None")
                    .foregroundStyle(current == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12.5))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: Self.groupWidth - 10, alignment: .leading)
        .help("Pick the group of this repository, or of every selected one")
        .accessibilityLabel("Group")
        .accessibilityValue(current?.displayName ?? "None")
    }

    @ViewBuilder
    private var access: some View {
        let status = model.status(for: repo)
        HStack(spacing: 6) {
            switch (model.authMethod, status?.problem, status) {
            case (nil, _, _):
                Text("Signed out").foregroundStyle(.secondary)
            case (_, .noAccess, _):
                Label("No access", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                Button("Grant…") { model.open(model.manageAccessURL) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.link)
            case (_, .error(let message), _):
                Label("Error", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                    .help(message)
            case (let method?, nil, let status?):
                Label(
                    "\(status.isPrivate ? "Private" : "Public") · \(method == .githubApp ? "app" : "gh")",
                    systemImage: status.isPrivate ? "lock" : "globe"
                )
                .foregroundStyle(.secondary)
            case (_, nil, nil):
                Text("Checking…").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
    }
}

/// The 2x3 drag handle in front of each repository row.
private struct GripDots: View {
    var body: some View {
        Grid(horizontalSpacing: 2.5, verticalSpacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Groups

/// Creates a group or edits one: its name and which repositories it holds.
package struct GroupEditorSheet: View {
    let model: AppModel
    let editor: GroupEditor
    let saved: (RepoGroup.ID) -> Void
    @State private var name: String
    @State private var members: Set<TrackedRepo.ID>
    @State private var query = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var filterFocused: Bool

    package init(model: AppModel, editor: GroupEditor, saved: @escaping (RepoGroup.ID) -> Void = { _ in }) {
        self.model = model
        self.editor = editor
        self.saved = saved
        let repos = model.prefs.repos
        switch editor {
        case .new(let ids):
            _name = State(initialValue: repos.unusedGroupName())
            _members = State(initialValue: Set(ids))
        case .edit(let id):
            _name = State(initialValue: repos.group(id)?.name ?? "")
            _members = State(initialValue: Set(repos.members(of: id).map(\.id)))
        }
    }

    private var groupID: RepoGroup.ID? {
        if case .edit(let id) = editor { id } else { nil }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var shown: [TrackedRepo] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let items = model.prefs.repos.items
        return needle.isEmpty ? items : items.filter { $0.ref.key.contains(needle) }
    }

    private var allShownSelected: Bool { !shown.isEmpty && shown.allSatisfy { members.contains($0.id) } }

    package var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(groupID == nil ? "New Group" : "Edit Group")
                .font(.system(size: 15, weight: .semibold))

            SheetField(prompt: "Group name", text: $name, focused: $nameFocused)
                .accessibilityLabel("Group name")

            HStack(alignment: .firstTextBaseline) {
                Text("Repositories")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(members.count) selected · ticking one in another group moves it here")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(allShownSelected ? "Deselect All" : "Select All") {
                    let ids = shown.map(\.id)
                    if allShownSelected { members.subtract(ids) } else { members.formUnion(ids) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.link)
                .font(.system(size: 12.5))
                .disabled(shown.isEmpty)
            }

            SheetField(prompt: "Filter repositories", text: $query, symbol: "magnifyingglass", focused: $filterFocused)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { repo in
                        PickerRow(name: title(repo), detail: detail(repo), isAdded: false, isSelected: members.contains(repo.id)) {
                            if members.remove(repo.id) == nil { members.insert(repo.id) }
                        }
                    }
                    if shown.isEmpty {
                        Text(model.prefs.repos.items.isEmpty ? "No repositories yet." : "No matches.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                }
            }
            .frame(height: 260)
            .settingsTable()

            HStack {
                if let groupID {
                    Button("Delete Group") {
                        model.removeGroup(groupID)
                        close()
                    }
                    .help("Delete the group. Its repositories stay in Shipwatch, ungrouped.")
                }
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button(groupID == nil ? "Create Group" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
            }
            .controlSize(.large)
            .font(.system(size: 13))
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.settingsContent)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .task { nameFocused = true }
    }

    private func title(_ repo: TrackedRepo) -> AttributedString {
        var title = AttributedString(repo.ref.name)
        var owner = AttributedString("  \(repo.ref.owner)")
        owner.foregroundColor = .secondary
        title.append(owner)
        return title
    }

    private func detail(_ repo: TrackedRepo) -> Text {
        var parts: [String] = []
        if let other = repo.group, other != groupID, let group = model.prefs.repos.group(other) {
            parts.append("In \(group.displayName)")
        }
        if repo.hidden { parts.append("Hidden") }
        return Text(parts.joined(separator: " · "))
    }

    private func save() {
        let ids = model.prefs.repos.items.map(\.id).filter(members.contains)
        if let id = model.saveGroup(groupID, name: trimmedName, members: ids) { saved(id) }
        close()
    }

    private func close() {
        model.groupEditor = nil
    }
}

/// A text field styled for the Settings sheets, with an optional leading symbol.
struct SheetField: View {
    let prompt: String
    @Binding var text: String
    var symbol: String?
    var focused: FocusState<Bool>.Binding
    /// Shows a button that empties the field while it has text.
    var clearable = false

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
            if clearable && !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused.wrappedValue ? Color.accentColor : .white.opacity(0.1), lineWidth: focused.wrappedValue ? 2 : 0.5)
        )
    }
}

// MARK: - Add Repositories

/// State for the "Add Repositories" sheet.
@MainActor
@Observable
package final class RepoPickerModel {
    package var listings: [RepoListing] = []
    package var query = ""
    package var selected = Set<String>()
    package var isLoading = false
    package var error: String?

    package init() {}

    func load(from model: AppModel) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            listings = try await model.repositoryListings()
        } catch {
            uiLog.error("Could not list repositories: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    /// Matching listings grouped by owner, the signed-in user first, newest push first.
    func groups(ownLogin: String?) -> [(owner: String, repos: [RepoListing])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty ? listings : listings.filter {
            needle.contains("/") ? $0.ref.key.contains(needle) : $0.name.lowercased().contains(needle)
        }
        let grouped = Dictionary(grouping: matching) { $0.owner.login }
        let own = ownLogin?.lowercased()
        return grouped.keys
            .sorted { lhs, rhs in
                if lhs.lowercased() == own { return true }
                if rhs.lowercased() == own { return false }
                return lhs.lowercased() < rhs.lowercased()
            }
            .map { owner in
                (owner, grouped[owner, default: []].sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) })
            }
    }

    /// A full `owner/name` typed into the search field that isn't in the list.
    var typedRef: RepoRef? {
        guard query.contains("/"), let ref = RepoRef(parsing: query) else { return nil }
        return listings.contains { $0.id == ref.key } ? nil : ref
    }

    func toggle(_ key: String) {
        if selected.contains(key) {
            selected.remove(key)
        } else {
            selected.insert(key)
        }
    }

    func selectedRefs() -> [RepoRef] {
        var refs = listings.filter { selected.contains($0.id) }.map(\.ref)
        if let typed = typedRef, selected.contains(typed.key) {
            refs.append(typed)
        }
        return refs
    }
}

package struct AddRepositoriesSheet: View {
    let model: AppModel
    @State private var picker: RepoPickerModel
    private let loadsOnAppear: Bool
    @FocusState private var searchFocused: Bool

    package init(model: AppModel, picker: RepoPickerModel = RepoPickerModel(), loadsOnAppear: Bool = true) {
        self.model = model
        _picker = State(initialValue: picker)
        self.loadsOnAppear = loadsOnAppear
    }

    private var selectionCount: Int { picker.selectedRefs().count }

    package var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Repositories")
                    .font(.system(size: 15, weight: .semibold))
                Text("Repositories your token can read. Already added ones are greyed out.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            SheetField(prompt: "Filter, or type owner/name", text: $picker.query, symbol: "magnifyingglass", focused: $searchFocused)

            list
                .frame(height: 290)
                .settingsTable()

            HStack {
                if model.authMethod == .githubApp {
                    Button { model.open(model.manageAccessURL) } label: {
                        Label("Grant access to more repos", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.link)
                }
                Spacer()
                Button("Cancel") { model.isAddingRepositories = false }
                    .keyboardShortcut(.cancelAction)
                Button(selectionCount == 0 ? "Add Repositories" : "Add \(selectionCount.counted("Repository", "Repositories"))") {
                    model.addRepositories(picker.selectedRefs())
                    model.isAddingRepositories = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectionCount == 0)
            }
            .controlSize(.large)
            .font(.system(size: 13))
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.settingsContent)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .task {
            searchFocused = true
            if loadsOnAppear { await picker.load(from: model) }
        }
    }

    @ViewBuilder
    private var list: some View {
        if picker.isLoading && picker.listings.isEmpty {
            ProgressView("Loading repositories…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = picker.error, picker.listings.isEmpty {
            VStack(spacing: 8) {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await picker.load(from: model) } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let groups = picker.groups(ownLogin: model.user?.login)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let typed = picker.typedRef {
                        groupHeader(typed.owner, symbol: "keyboard")
                        PickerRow(
                            name: highlighted(typed.fullName),
                            detail: Text("Typed"),
                            isAdded: model.prefs.repos.contains(typed),
                            isSelected: picker.selected.contains(typed.key)
                        ) { picker.toggle(typed.key) }
                    }
                    ForEach(groups, id: \.owner) { group in
                        groupHeader(group.owner, symbol: "person")
                        ForEach(group.repos) { listing in
                            PickerRow(
                                name: highlighted(listing.name),
                                detail: detail(for: listing),
                                isAdded: model.prefs.repos.contains(listing.ref),
                                isSelected: picker.selected.contains(listing.id)
                            ) { picker.toggle(listing.id) }
                        }
                    }
                    if groups.isEmpty && picker.typedRef == nil {
                        Text(picker.query.isEmpty ? "No repositories found." : "No matches. Type owner/name to add any repository your token can read.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                }
            }
        }
    }

    private func groupHeader(_ owner: String, symbol: String) -> some View {
        Label(owner, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04))
    }

    private func detail(for listing: RepoListing) -> Text {
        let visibility = listing.private ? "Private" : "Public"
        let age = listing.pushedAt.map { " · \(RelativeTime.ago($0))" } ?? ""
        return Text("\(Image(systemName: listing.private ? "lock" : "globe")) \(visibility)\(age)")
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = picker.query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, !needle.contains("/"), let range = attributed.range(of: needle, options: .caseInsensitive) else {
            return attributed
        }
        attributed[range].backgroundColor = Theme.running.opacity(0.32)
        return attributed
    }
}

struct PickerRow: View {
    let name: AttributedString
    let detail: Text
    let isAdded: Bool
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { isAdded || isSelected }, set: { _ in toggle() }))
                    .toggleStyle(.blueCheckbox)
                    .labelsHidden()
                    .disabled(isAdded)
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(isAdded ? .tertiary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Group {
                    if isAdded {
                        Text("Added")
                    } else {
                        detail
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { if !isAdded { toggle() } }
            Divider().padding(.leading, 12)
        }
    }
}
