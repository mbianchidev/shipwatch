import ShipwatchCore
import SwiftUI

struct RepositoriesSettingsView: View {
    let model: AppModel
    @State private var selection = Set<String>()
    @FocusState private var focusedGroup: RepoGroup.ID?
    private static let listRowInset: CGFloat = 8

    private var repos: RepoList { model.prefs.repos }
    private var rows: [RepoListRow] { repos.rows }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repositories shown in the menu, in this order. Drag to reorder or into a group, click the eye to hide or show. Groups collapse into one row in the menu.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                header
                Divider()
                if rows.isEmpty {
                    VStack(spacing: 6) {
                        Text("No repositories yet")
                            .font(.system(size: 13, weight: .medium))
                        Text("Click + to pick repositories your token can read.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    List(selection: $selection) {
                        ForEach(rows) { row in
                            Group {
                                switch row {
                                case .group(let group):
                                    GroupSettingsRow(model: model, group: group, focus: $focusedGroup) { removeGroup(group.id) }
                                case .repo(let repo):
                                    RepoSettingsRow(model: model, repo: repo) { targets(for: repo) } newGroup: { newGroup(with: $0) }
                                }
                            }
                            .tag(row.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                        }
                        .onMove { model.prefs.repos.moveRows(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .alternatingRowBackgrounds()
                    .environment(\.defaultMinListRowHeight, RepoSettingsRow.height)
                    .frame(height: RepoSettingsRow.height * CGFloat(min(max(rows.count, 4), 11)))
                    .onDeleteCommand(perform: removeSelection)
                }
                Divider()
                footer
            }
            .settingsTable()
        }
        .sheet(isPresented: Binding(get: { model.isAddingRepositories }, set: { model.isAddingRepositories = $0 })) {
            AddRepositoriesSheet(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 28)
            Text("Show").frame(width: 46, alignment: .leading)
            Text("Repository")
            Spacer()
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
            Button { newGroup(with: selectedRepoIDs) } label: {
                Image(systemName: "folder.badge.plus").frame(width: 34, height: 24)
            }
            .help(selectedRepoIDs.isEmpty ? "New group" : "New group with the selected repositories")
            .accessibilityLabel("New group")
            Divider().frame(height: 24)
            Spacer()
            Text(summary)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.trailing, 12)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
    }

    private var summary: String {
        var parts = [repos.items.count.counted("repository", "repositories")]
        if !repos.groups.isEmpty { parts.append(repos.groups.count.counted("group")) }
        parts.append("\(repos.hiddenCount) hidden")
        return parts.joined(separator: " · ")
    }

    private var selectedRepoIDs: [TrackedRepo.ID] {
        repos.items.map(\.id).filter(selection.contains)
    }

    /// A row's menu acts on the whole selection when the row is part of it.
    private func targets(for repo: TrackedRepo) -> [TrackedRepo.ID] {
        selection.contains(repo.id) ? selectedRepoIDs : [repo.id]
    }

    private func newGroup(with ids: [TrackedRepo.ID]) {
        let id = model.createGroup(with: ids)
        selection = [RepoGroup.entryID(id)]
        DispatchQueue.main.async { focusedGroup = id }
    }

    private func removeGroup(_ id: RepoGroup.ID) {
        selection.remove(RepoGroup.entryID(id))
        model.removeGroup(id)
    }

    private func removeSelection() {
        for group in repos.groups where selection.contains(group.entryID) {
            model.removeGroup(group.id)
        }
        for id in selectedRepoIDs {
            model.removeRepository(id)
        }
        selection = []
    }
}

/// A group's header row: its name, editable in place, and how many repositories it holds.
struct GroupSettingsRow: View {
    let model: AppModel
    let group: RepoGroup
    var focus: FocusState<RepoGroup.ID?>.Binding
    let ungroup: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            GripDots()
                .frame(width: 28)
                .help("Drag to move the group")
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.leading, 7)
                .frame(width: 46, alignment: .leading)
                .accessibilityHidden(true)
            TextField("Group name", text: Binding(get: { group.name }, set: { model.renameGroup(group.id, to: $0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .focused(focus, equals: group.id)
                .accessibilityLabel("Group name")
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Text(model.prefs.repos.members(of: group.id).count.counted("repository", "repositories"))
                    .foregroundStyle(.secondary)
                Button("Ungroup", action: ungroup)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.link)
                    .help("Delete the group. Its repositories stay in Shipwatch.")
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .frame(width: RepoSettingsRow.accessWidth, alignment: .leading)
        }
        .padding(.trailing, 12)
        .frame(height: RepoSettingsRow.height)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename") { focus.wrappedValue = group.id }
            Button("Ungroup", action: ungroup)
        }
    }
}

struct RepoSettingsRow: View {
    static let accessWidth: CGFloat = 170
    static let height: CGFloat = 32
    let model: AppModel
    let repo: TrackedRepo
    /// The repositories the row's menu acts on.
    let targets: () -> [TrackedRepo.ID]
    let newGroup: ([TrackedRepo.ID]) -> Void

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
            .frame(width: 46, alignment: .leading)
            .help(repo.hidden ? "Show in the menu" : "Hide from the menu")
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(repo.ref.name)
                    .foregroundStyle(repo.hidden ? .secondary : .primary)
                Text(repo.ref.owner)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.leading, repo.group == nil ? 0 : 18)
            Spacer(minLength: 8)
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
                Button("New Group") { newGroup(targets()) }
            }
            if repo.group != nil {
                Button("Remove from Group") { model.setGroup(targets(), to: nil) }
            }
        }
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

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter, or type owner/name", text: $picker.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(searchFocused ? Color.accentColor : .white.opacity(0.1), lineWidth: searchFocused ? 2 : 0.5)
            )

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
                    .toggleStyle(.checkbox)
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
