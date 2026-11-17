import Foundation

/// A versioned JSON file only the user can read, in a folder only the user can open, written atomically.
struct SupportFile: Sendable {
    private struct Header: Decodable { var version: Int }

    let url: URL

    /// `nil` when nothing was saved yet or the file holds another `version`.
    func load<Value: Decodable>(_ type: Value.Type, version: Int) throws -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let decoder = JSONDecoder()
        guard try decoder.decode(Header.self, from: data).version == version else { return nil }
        return try decoder.decode(Value.self, from: data)
    }

    func save(_ value: some Encodable) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func remove() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
