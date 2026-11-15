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

    /// `nil` when nothing was saved yet or the snapshot is from another version.
    public func load() throws -> StatusSnapshot? {
        struct Header: Decodable { var version: Int }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let decoder = JSONDecoder()
        guard try decoder.decode(Header.self, from: data).version == StatusSnapshot.currentVersion else { return nil }
        return try decoder.decode(StatusSnapshot.self, from: data)
    }

    public func save(_ snapshot: StatusSnapshot) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
