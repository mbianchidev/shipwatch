import Foundation

/// The statuses of the last successful refresh.
public struct StatusSnapshot: Codable, Equatable, Sendable {
    /// Bump when `RepoStatus` changes in a way older snapshots can't express; other versions are ignored.
    public static let currentVersion = 2

    public var version: Int
    public var savedAt: Date
    /// Keyed by `RepoRef.key`.
    public var statuses: [String: RepoStatus]

    public init(savedAt: Date, statuses: [String: RepoStatus]) {
        version = Self.currentVersion
        self.savedAt = savedAt
        self.statuses = statuses
    }
}

/// Keeps the last refresh on disk, so a relaunch (after an update, at login) lists every repository right away
/// instead of loading them all again. Readable only by the user, like the update state next to it.
public struct StatusCache: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    private var file: SupportFile { SupportFile(url: url) }

    /// `nil` when nothing was saved yet or the snapshot is from another version.
    public func load() throws -> StatusSnapshot? {
        try file.load(StatusSnapshot.self, version: StatusSnapshot.currentVersion)
    }

    public func save(_ snapshot: StatusSnapshot) throws {
        try file.save(snapshot)
    }

    public func remove() throws {
        try file.remove()
    }
}
