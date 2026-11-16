import Foundation

public struct TrackedRepo: Codable, Equatable, Sendable, Identifiable {
    public var ref: RepoRef
    public var hidden: Bool
    public var group: RepoGroup.ID?
    /// Names the repository had before GitHub reported a rename or transfer, so clones with old remotes still match.
    public var formerRefs: [RepoRef]

    public init(ref: RepoRef, hidden: Bool = false, group: RepoGroup.ID? = nil, formerRefs: [RepoRef] = []) {
        self.ref = ref
        self.hidden = hidden
        self.group = group
        self.formerRefs = formerRefs
    }

    public var id: String { ref.key }

    enum CodingKeys: String, CodingKey { case ref, hidden, group, formerRefs }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(RepoRef.self, forKey: .ref)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        group = try container.decodeIfPresent(RepoGroup.ID.self, forKey: .group)
        formerRefs = try container.decodeIfPresent([RepoRef].self, forKey: .formerRefs) ?? []
    }
}

/// A named set of repositories the menu shows as one collapsible row.
public struct RepoGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Whether the menu lists the members, kept across launches.
    public var isExpanded: Bool

    public init(id: UUID = UUID(), name: String, isExpanded: Bool = false) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
    }

    public var entryID: String { Self.entryID(id) }

    /// The name as typed, or "Untitled Group" while it's blank.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Group" : trimmed
    }

    /// Distinct from every `RepoRef.key`, which always contains a slash.
    public static func entryID(_ id: UUID) -> String { "group:\(id.uuidString)" }

    enum CodingKeys: String, CodingKey { case id, name, isExpanded }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? false
    }
}

/// A top-level row of the menu: a repository on its own, or a group with its members.
public enum RepoListEntry: Equatable, Sendable, Identifiable {
    case repo(TrackedRepo)
    case group(RepoGroup, members: [TrackedRepo])

    public var id: String {
        switch self {
        case .repo(let repo): repo.id
        case .group(let group, _): group.entryID
        }
    }

    public var repos: [TrackedRepo] {
        switch self {
        case .repo(let repo): [repo]
        case .group(_, let members): members
        }
    }
}

/// A row of the Settings table: group headers followed by their members, in menu order.
public enum RepoListRow: Equatable, Sendable, Identifiable {
    case group(RepoGroup)
    case repo(TrackedRepo)

    public var id: String {
        switch self {
        case .group(let group): group.entryID
        case .repo(let repo): repo.id
        }
    }
}

/// What a Settings search field matches: text anywhere in `owner/name`, a group name or a path, ignoring case.
/// Blank text matches everything.
public struct SearchText: Equatable, Sendable {
    public let needle: String

    public init(_ text: String) {
        needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var isEmpty: Bool { needle.isEmpty }

    public func matches(_ candidates: String...) -> Bool {
        isEmpty || candidates.contains { $0.lowercased().contains(needle) }
    }
}

/// An organization or user that owns tracked repositories, for the menu's owner filter.
public struct RepoOwner: Equatable, Sendable, Identifiable {
    /// The login as the first of its tracked repositories spells it.
    public var login: String
    public var count: Int

    public init(login: String, count: Int) {
        self.login = login
        self.count = count
    }

    /// Matches `RepoRef.ownerKey`.
    public var id: String { login.lowercased() }
}

public enum RepoSort: String, CaseIterable, Sendable {
    case custom, name, activity

    public var label: String {
        switch self {
        case .custom: "Custom"
        case .name: "Name"
        case .activity: "Last Activity"
        }
    }
}

/// The user's repositories and groups. The order of `items` is the custom menu order; members of a group are
/// always next to each other, and the group sits where its first member is.
public struct RepoList: Codable, Equatable, Sendable {
    public private(set) var items: [TrackedRepo]
    public private(set) var groups: [RepoGroup]

    public init(_ items: [TrackedRepo] = [], groups: [RepoGroup] = []) {
        self.items = []
        self.groups = []
        for group in groups where !self.groups.contains(where: { $0.id == group.id }) {
            self.groups.append(group)
        }
        for item in items where !contains(item.ref) {
            self.items.append(item)
        }
        normalize()
    }

    enum CodingKeys: String, CodingKey { case items, groups }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try container.decode([TrackedRepo].self, forKey: .items),
            groups: try container.decodeIfPresent([RepoGroup].self, forKey: .groups) ?? []
        )
    }

    public var visible: [TrackedRepo] { items.filter { !$0.hidden } }
    public var hiddenCount: Int { items.count(where: \.hidden) }

    public func contains(_ ref: RepoRef) -> Bool {
        items.contains { $0.id == ref.key }
    }

    public func group(_ id: RepoGroup.ID) -> RepoGroup? {
        groups.first { $0.id == id }
    }

    public func members(of id: RepoGroup.ID) -> [TrackedRepo] {
        items.filter { $0.group == id }
    }

    /// Owners of the repositories `include` accepts, alphabetically, with how many of them each owns.
    public func owners(including include: (TrackedRepo) -> Bool = { _ in true }) -> [RepoOwner] {
        var owners: [String: RepoOwner] = [:]
        for item in items where include(item) {
            owners[item.ref.ownerKey, default: RepoOwner(login: item.ref.owner, count: 0)].count += 1
        }
        return owners.values.sorted { $0.login.localizedStandardCompare($1.login) == .orderedAscending }
    }

    /// Former names of tracked repositories, by `RepoRef.key`, mapped to the current name.
    public var aliases: [String: RepoRef] {
        var aliases: [String: RepoRef] = [:]
        for item in items {
            for former in item.formerRefs where !contains(former) {
                aliases[former.key] = item.ref
            }
        }
        return aliases
    }

    // MARK: Repositories

    /// Appends repositories that aren't tracked yet and returns how many were added.
    @discardableResult
    public mutating func add(_ refs: [RepoRef]) -> Int {
        var added = 0
        for ref in refs where !contains(ref) {
            items.append(TrackedRepo(ref: ref))
            added += 1
        }
        return added
    }

    public mutating func remove(_ id: TrackedRepo.ID) {
        items.removeAll { $0.id == id }
    }

    public mutating func setHidden(_ id: TrackedRepo.ID, _ hidden: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].hidden = hidden
    }

    /// Points a tracked repository at the name GitHub now reports for it. When the new name is tracked as well,
    /// the old entry is dropped and the existing one keeps its place, group and visibility.
    @discardableResult
    public mutating func rename(_ id: TrackedRepo.ID, to ref: RepoRef) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].ref != ref else { return false }
        let old = items[index]
        let former = old.ref.key == ref.key ? old.formerRefs : old.formerRefs + [old.ref]
        if ref.key != id, let existing = items.firstIndex(where: { $0.id == ref.key }) {
            items[existing].formerRefs = Self.merged(items[existing].formerRefs, former, excluding: ref)
            items.remove(at: index)
        } else {
            items[index].ref = ref
            items[index].formerRefs = Self.merged([], former, excluding: ref)
        }
        return true
    }

    private static func merged(_ lhs: [RepoRef], _ rhs: [RepoRef], excluding current: RepoRef) -> [RepoRef] {
        var seen: Set<String> = [current.key]
        return (lhs + rhs).filter { seen.insert($0.key).inserted }
    }

    // MARK: Groups

    /// Creates a group holding `members`, placed where the first of them is, or at the end when empty.
    @discardableResult
    public mutating func addGroup(named name: String, members: [TrackedRepo.ID] = []) -> RepoGroup.ID {
        let group = RepoGroup(name: name)
        groups.append(group)
        let ids = Set(members)
        for index in items.indices where ids.contains(items[index].id) {
            items[index].group = group.id
        }
        normalize()
        return group.id
    }

    /// "New Group", or "New Group 2" and so on when that name is taken.
    public func unusedGroupName(_ base: String = "New Group") -> String {
        let taken = Set(groups.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    public mutating func renameGroup(_ id: RepoGroup.ID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name
    }

    /// Deletes the group; its repositories stay where they are, ungrouped.
    public mutating func removeGroup(_ id: RepoGroup.ID) {
        groups.removeAll { $0.id == id }
        for index in items.indices where items[index].group == id {
            items[index].group = nil
        }
    }

    /// Makes `members` exactly the group's repositories: new ones join after the current members, dropped ones
    /// stay where they are, ungrouped.
    public mutating func setMembers(of id: RepoGroup.ID, to members: [TrackedRepo.ID]) {
        guard group(id) != nil else { return }
        let wanted = Set(members)
        setGroup(items.filter { $0.group == id && !wanted.contains($0.id) }.map(\.id), to: nil)
        setGroup(items.filter { $0.group != id && wanted.contains($0.id) }.map(\.id), to: id)
    }

    public mutating func setGroupExpanded(_ id: RepoGroup.ID, _ expanded: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].isExpanded = expanded
    }

    /// Moves repositories into a group, after its current members, or out of any group with `nil`.
    public mutating func setGroup(_ ids: [TrackedRepo.ID], to group: RepoGroup.ID?) {
        guard group.map({ self.group($0) != nil }) ?? true else { return }
        let ids = Set(ids)
        let moving = items.filter { ids.contains($0.id) && $0.group != group }
        guard !moving.isEmpty else { return }
        if let group, items.contains(where: { $0.group == group }) {
            items.removeAll { item in moving.contains { $0.id == item.id } }
            let end = (items.lastIndex { $0.group == group } ?? items.count - 1) + 1
            items.insert(contentsOf: moving.map { var item = $0; item.group = group; return item }, at: end)
        } else {
            for index in items.indices where ids.contains(items[index].id) {
                items[index].group = group
            }
        }
        normalize()
    }

    // MARK: Layout

    /// Top-level menu entries for the repositories `include` accepts, in custom order. Groups none of whose members
    /// are included are left out, unless `emptyGroups` is set: then they come last.
    public func entries(emptyGroups: Bool = false, including include: (TrackedRepo) -> Bool = { _ in true }) -> [RepoListEntry] {
        var entries: [RepoListEntry] = []
        var placed = Set<RepoGroup.ID>()
        for item in items where include(item) {
            guard let id = item.group, let group = group(id) else {
                entries.append(.repo(item))
                continue
            }
            if placed.insert(id).inserted {
                entries.append(.group(group, members: items.filter { $0.group == id && include($0) }))
            }
        }
        if emptyGroups {
            for group in groups where !placed.contains(group.id) {
                entries.append(.group(group, members: []))
            }
        }
        return entries
    }

    /// Every group and repository as Settings lists them.
    public var rows: [RepoListRow] { rows(collapsing: []) }

    /// Settings rows without the members of the `collapsed` groups.
    public func rows(collapsing collapsed: Set<RepoGroup.ID>) -> [RepoListRow] {
        entries(emptyGroups: true).flatMap { entry -> [RepoListRow] in
            switch entry {
            case .repo(let repo): [.repo(repo)]
            case .group(let group, let members): [.group(group)] + (collapsed.contains(group.id) ? [] : members.map { .repo($0) })
            }
        }
    }

    /// Settings rows for `search`: matching repositories under their group's header, and every member of a group
    /// whose name matches. Groups stay open while searching, so no match is left out.
    public func rows(collapsing collapsed: Set<RepoGroup.ID>, matching search: SearchText) -> [RepoListRow] {
        guard !search.isEmpty else { return rows(collapsing: collapsed) }
        return entries(emptyGroups: true).flatMap { entry -> [RepoListRow] in
            switch entry {
            case .repo(let repo):
                return search.matches(repo.ref.fullName) ? [.repo(repo)] : []
            case .group(let group, let members):
                let groupMatches = search.matches(group.displayName)
                let shown = groupMatches ? members : members.filter { search.matches($0.ref.fullName) }
                return groupMatches || !shown.isEmpty ? [.group(group)] + shown.map { .repo($0) } : []
            }
        }
    }

    /// `moveRows` for a table showing `rows(collapsing:)`. Dropping right below a collapsed group lands after
    /// its hidden members, outside the group, even when it has none.
    public mutating func moveRows(fromOffsets source: IndexSet, toOffset destination: Int, collapsing collapsed: Set<RepoGroup.ID>) {
        let all = rows.map(\.id)
        let shown = rows(collapsing: collapsed).map(\.id)
        let offsets = shown.compactMap { all.firstIndex(of: $0) }
        guard offsets.count == shown.count else { return }
        let mapped = IndexSet(source.compactMap { offsets.indices.contains($0) ? offsets[$0] : nil })
        moveRows(fromOffsets: mapped, toOffset: offsets.indices.contains(destination) ? offsets[destination] : all.count, closed: collapsed)
    }

    /// Applies a drag in the Settings table, offsets as in SwiftUI's `move(fromOffsets:toOffset:)` over `rows`.
    /// A dragged group takes its members along and lands between top-level entries. Dragged repositories join
    /// the group they are dropped into; dropped right after a group's last member, only its own members stay in.
    public mutating func moveRows(fromOffsets source: IndexSet, toOffset destination: Int) {
        moveRows(fromOffsets: source, toOffset: destination, closed: [])
    }

    /// Repositories dropped right below the header of a `closed` group stay out of it.
    private mutating func moveRows(fromOffsets source: IndexSet, toOffset destination: Int, closed: Set<RepoGroup.ID>) {
        let rows = rows
        let source = IndexSet(source.filter { rows.indices.contains($0) })
        if let headerIndex = source.first(where: { if case .group = rows[$0] { true } else { false } }),
           case .group(let group) = rows[headerIndex] {
            moveGroup(group.id, toRowOffset: destination)
            return
        }
        guard !source.isEmpty else { return }
        let moving = source.map { rows[$0] }
        var reordered = rows
        let before = source.count(in: 0..<min(destination, rows.count))
        for index in source.sorted(by: >) { reordered.remove(at: index) }
        let insertAt = max(0, min(reordered.count, destination - before))
        let previous = insertAt > 0 ? reordered[insertAt - 1] : nil
        let next = insertAt < reordered.count ? reordered[insertAt] : nil
        reordered.insert(contentsOf: moving, at: insertAt)

        func target(for repo: TrackedRepo) -> RepoGroup.ID? {
            if case .repo(let neighbor)? = next, let group = neighbor.group { return group }
            if case .group(let group)? = previous, !closed.contains(group.id) { return group.id }
            if case .repo(let neighbor)? = previous, let group = neighbor.group, repo.group == group { return group }
            return nil
        }
        items = reordered.compactMap { row in
            guard case .repo(var repo) = row else { return nil }
            if moving.contains(where: { $0.id == repo.id }) { repo.group = target(for: repo) }
            return repo
        }
        normalize()
    }

    private mutating func moveGroup(_ id: RepoGroup.ID, toRowOffset destination: Int) {
        var entries = entries()
        guard let from = entries.firstIndex(where: { $0.id == RepoGroup.entryID(id) }) else { return }
        var starts: [Int] = []
        var offset = 0
        for entry in entries {
            starts.append(offset)
            if case .group(_, let members) = entry { offset += 1 + members.count } else { offset += 1 }
        }
        let to = starts.indices.filter { $0 != from && starts[$0] < destination }.count
        let entry = entries.remove(at: from)
        entries.insert(entry, at: to)
        items = entries.flatMap(\.repos)
    }

    /// Siblings `id` moves among with "Move Up" and "Move Down": the shown members of its group, or the shown
    /// top-level entries. `id` is a repository key or a `RepoGroup.entryID`.
    public func siblings(of id: String, including include: (TrackedRepo) -> Bool) -> [String] {
        if let repo = items.first(where: { $0.id == id }), let group = repo.group, self.group(group) != nil {
            return items.filter { $0.group == group && include($0) }.map(\.id)
        }
        return entries(including: include).map(\.id)
    }

    public func canMove(_ id: String, by offset: Int, including include: (TrackedRepo) -> Bool) -> Bool {
        let siblings = siblings(of: id, including: include)
        guard let position = siblings.firstIndex(of: id) else { return false }
        return siblings.indices.contains(position + offset)
    }

    /// Moves a repository or group past the next shown sibling, so hidden repos don't make "Move Up" look like a no-op.
    public mutating func move(_ id: String, by offset: Int, including include: (TrackedRepo) -> Bool) {
        let siblings = siblings(of: id, including: include)
        guard let position = siblings.firstIndex(of: id), siblings.indices.contains(position + offset) else { return }
        let target = siblings[position + offset]
        var entries = entries()
        if let from = entries.firstIndex(where: { $0.id == id }) {
            guard let to = entries.firstIndex(where: { $0.id == target }) else { return }
            let entry = entries.remove(at: from)
            entries.insert(entry, at: to)
            items = entries.flatMap(\.repos)
        } else if let from = items.firstIndex(where: { $0.id == id }), let to = items.firstIndex(where: { $0.id == target }) {
            let item = items.remove(at: from)
            items.insert(item, at: to)
        }
    }

    /// Drops references to deleted groups and pulls each group's members together at its first member.
    private mutating func normalize() {
        let known = Set(groups.map(\.id))
        for index in items.indices where items[index].group.map({ !known.contains($0) }) ?? false {
            items[index].group = nil
        }
        var placed = Set<RepoGroup.ID>()
        var ordered: [TrackedRepo] = []
        for item in items {
            guard let group = item.group else {
                ordered.append(item)
                continue
            }
            if placed.insert(group).inserted {
                ordered.append(contentsOf: items.filter { $0.group == group })
            }
        }
        items = ordered
    }
}

extension [RepoListEntry] {
    /// Sorts entries and the members of each group. Ties, and repos without activity, keep the custom order.
    public func sorted(by sort: RepoSort, activity: (TrackedRepo) -> Date?) -> [RepoListEntry] {
        switch sort {
        case .custom:
            return self
        case .name:
            let sortedEntries = map { entry -> RepoListEntry in
                guard case .group(let group, let members) = entry else { return entry }
                return .group(group, members: Self.stable(members) { Self.nameOrder($0.ref, $1.ref) })
            }
            return Self.stable(sortedEntries) { lhs, rhs in
                lhs.sortName.localizedStandardCompare(rhs.sortName) == .orderedAscending
            }
        case .activity:
            func newer(_ lhs: Date?, _ rhs: Date?) -> Bool {
                switch (lhs, rhs) {
                case (let lhs?, let rhs?): lhs > rhs
                case (.some, nil): true
                default: false
                }
            }
            let sortedEntries = map { entry -> RepoListEntry in
                guard case .group(let group, let members) = entry else { return entry }
                return .group(group, members: Self.stable(members) { newer(activity($0), activity($1)) })
            }
            return Self.stable(sortedEntries) { lhs, rhs in
                newer(lhs.repos.compactMap(activity).max(), rhs.repos.compactMap(activity).max())
            }
        }
    }

    private static func nameOrder(_ lhs: RepoRef, _ rhs: RepoRef) -> Bool {
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.owner.localizedStandardCompare(rhs.owner) == .orderedAscending
    }

    private static func stable<T>(_ values: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
        values.enumerated()
            .sorted { lhs, rhs in
                if areInIncreasingOrder(lhs.element, rhs.element) { return true }
                if areInIncreasingOrder(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

extension RepoListEntry {
    fileprivate var sortName: String {
        switch self {
        case .repo(let repo): "\(repo.ref.name) \(repo.ref.owner)"
        case .group(let group, _): group.displayName
        }
    }
}
