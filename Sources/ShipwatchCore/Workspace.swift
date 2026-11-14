import Foundation

/// A folder in the workspace whose git remote points at a tracked repository.
public struct LocalClone: Hashable, Sendable, Identifiable {
    public var path: URL
    public var ref: RepoRef
    /// The remote that points at `ref`, `origin` when several do.
    public var remote: String
    /// The checked-out branch at scan time, `nil` when HEAD is detached.
    public var headBranch: String?

    public init(path: URL, ref: RepoRef, remote: String, headBranch: String?) {
        self.path = path
        self.ref = ref
        self.remote = remote
        self.headBranch = headBranch
    }

    public var id: String { path.path }
}

public struct WorkspaceScan: Equatable, Sendable {
    public var clones: [LocalClone]
    /// Folders that could not be listed, usually because macOS privacy settings block them.
    public var unreadable: [URL]

    public init(clones: [LocalClone] = [], unreadable: [URL] = []) {
        self.clones = clones
        self.unreadable = unreadable
    }
}

/// Finds clones of tracked repositories inside the workspace folder. Reads files only; never runs git.
public struct WorkspaceScanner: Sendable {
    public static let maxDepth = 3
    public static let skippedFolderNames: Set<String> = ["node_modules"]

    public var root: URL
    public var excluded: [URL]

    public init(root: URL, excluded: [URL] = []) {
        self.root = root
        self.excluded = excluded
    }

    /// `tracked` holds `RepoRef.key` values. Every clone of a tracked repository is returned, sorted by path.
    public func scan(tracked: Set<String>) -> WorkspaceScan {
        let excludedPaths = excluded.map { Self.canonical($0).path }
        var result = WorkspaceScan()
        visit(Self.canonical(root), depth: 0, tracked: tracked, excluded: excludedPaths, into: &result)
        result.clones.sort { $0.path.path.localizedStandardCompare($1.path.path) == .orderedAscending }
        return result
    }

    /// `realpath`, not `resolvingSymlinksInPath`: the latter drops `/private` while directory listings keep it,
    /// so exclusions would silently stop matching. Paths that no longer exist are only standardized.
    public static func canonical(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        guard let resolved = realpath(standardized.path, nil) else { return standardized }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    static func isExcluded(_ path: String, by excluded: [String]) -> Bool {
        excluded.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    private func visit(_ directory: URL, depth: Int, tracked: Set<String>, excluded: [String], into result: inout WorkspaceScan) {
        guard !Self.isExcluded(directory.path, by: excluded) else { return }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path, isDirectory: &isDirectory) {
            // A `.git` file means a linked worktree or a submodule; their main repository is handled on its own.
            if isDirectory.boolValue, let clone = Self.clone(at: directory, tracked: tracked) {
                result.clones.append(clone)
            }
            return
        }
        guard depth < Self.maxDepth else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            result.unreadable.append(directory)
            return
        }
        for child in children {
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true,
                  !Self.skippedFolderNames.contains(child.lastPathComponent)
            else { continue }
            visit(child, depth: depth + 1, tracked: tracked, excluded: excluded, into: &result)
        }
    }

    static func clone(at directory: URL, tracked: Set<String>) -> LocalClone? {
        let gitDirectory = directory.appendingPathComponent(".git")
        guard let config = try? String(contentsOf: gitDirectory.appendingPathComponent("config"), encoding: .utf8) else { return nil }
        let matches = GitConfig.remotes(in: config).compactMap { remote -> (name: String, ref: RepoRef)? in
            guard let ref = RepoRef(gitRemote: remote.url), tracked.contains(ref.key) else { return nil }
            return (remote.name, ref)
        }
        guard let match = matches.first(where: { $0.name == "origin" }) ?? matches.first else { return nil }
        let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8)
        return LocalClone(path: directory, ref: match.ref, remote: match.name, headBranch: head.flatMap(GitConfig.branch(fromHead:)))
    }
}

/// Just enough of git's config format to read remote URLs without running git.
enum GitConfig {
    struct Remote: Equatable {
        var name: String
        var url: String
    }

    /// Remotes in file order, each with its first `url`. Names starting with `-` are dropped so they can't become git options.
    static func remotes(in text: String) -> [Remote] {
        var remotes: [Remote] = []
        var current: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                current = remoteName(inHeader: line)
                continue
            }
            guard let name = current, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "url", !remotes.contains(where: { $0.name == name }) else { continue }
            let value = unquote(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            if !value.isEmpty { remotes.append(Remote(name: name, url: value)) }
        }
        return remotes
    }

    private static func remoteName(inHeader line: String) -> String? {
        guard let close = line.lastIndex(of: "]") else { return nil }
        let inner = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        let name: String
        if inner.lowercased().hasPrefix("remote "), inner.hasSuffix("\""), let open = inner.firstIndex(of: "\"") {
            let start = inner.index(after: open)
            let end = inner.index(before: inner.endIndex)
            guard start <= end else { return nil }
            name = String(inner[start..<end])
        } else if inner.lowercased().hasPrefix("remote.") {
            name = String(inner.dropFirst(7))
        } else {
            return nil
        }
        return name.isEmpty || name.hasPrefix("-") ? nil : name
    }

    private static func unquote(_ value: String) -> String {
        if value.hasPrefix("\"") {
            let body = value.dropFirst()
            return String(body[..<(body.firstIndex(of: "\"") ?? body.endIndex)])
        }
        let comment = value.firstIndex { $0 == "#" || $0 == ";" }
        return String(value[..<(comment ?? value.endIndex)]).trimmingCharacters(in: .whitespaces)
    }

    static func branch(fromHead text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard line.hasPrefix(prefix) else { return nil }
        let branch = String(line.dropFirst(prefix.count))
        return branch.isEmpty ? nil : branch
    }
}

extension RepoRef {
    static let gitHubHosts: Set<String> = ["github.com", "www.github.com", "ssh.github.com"]

    /// Parses a git remote URL that points at github.com: `git@github.com:owner/name.git`,
    /// `https://github.com/owner/name(.git)`, `ssh://git@github.com/owner/name.git` and `git://` forms.
    /// Local paths and other hosts return `nil`.
    public init?(gitRemote raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var authority: Substring
        var path: Substring
        if let separator = text.range(of: "://") {
            let scheme = text[..<separator.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme) else { return nil }
            let rest = text[separator.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            authority = rest[..<slash]
            path = rest[rest.index(after: slash)...]
            if let colon = authority.lastIndex(of: ":"), !authority[colon...].contains("@") {
                authority = authority[..<colon]
            }
        } else {
            // scp-like syntax: [user@]host:path. A slash before the colon means a local path.
            guard let colon = text.firstIndex(of: ":") else { return nil }
            authority = text[..<colon]
            guard !authority.contains("/") else { return nil }
            path = text[text.index(after: colon)...]
            while path.hasPrefix("/") { path = path.dropFirst() }
        }
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        guard Self.gitHubHosts.contains(authority.lowercased()) else { return nil }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.lowercased().hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        let name = String(parts[1])
        guard Self.isValidOwner(owner), Self.isValidName(name) else { return nil }
        self.init(owner: owner, name: name)
    }
}
