import Foundation

public struct TrackedRepo: Codable, Equatable, Sendable, Identifiable {
    public var ref: RepoRef
    public var hidden: Bool

    public init(ref: RepoRef, hidden: Bool = false) {
        self.ref = ref
        self.hidden = hidden
    }

    public var id: String { ref.key }
}

/// The user's ordered list of repositories. Order is the menu order.
public struct RepoList: Codable, Equatable, Sendable {
    public private(set) var items: [TrackedRepo]

    public init(_ items: [TrackedRepo] = []) {
        self.items = []
        for item in items where !contains(item.ref) {
            self.items.append(item)
        }
    }

    public var visible: [TrackedRepo] { items.filter { !$0.hidden } }
    public var hiddenCount: Int { items.count(where: \.hidden) }

    public func contains(_ ref: RepoRef) -> Bool {
        items.contains { $0.id == ref.key }
    }

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

    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().filter { items.indices.contains($0) }.map { items[$0] }
        let before = source.count(in: 0..<min(destination, items.count))
        for index in source.sorted(by: >) where items.indices.contains(index) {
            items.remove(at: index)
        }
        let insertAt = max(0, min(items.count, destination - before))
        items.insert(contentsOf: moving, at: insertAt)
    }

    /// Moves within the visible order, so hidden repos don't make "Move Up" look like a no-op.
    public mutating func moveVisible(_ id: TrackedRepo.ID, by offset: Int) {
        let visibleIDs = visible.map(\.id)
        guard let position = visibleIDs.firstIndex(of: id) else { return }
        let target = position + offset
        guard visibleIDs.indices.contains(target),
              let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == visibleIDs[target] })
        else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }
}
