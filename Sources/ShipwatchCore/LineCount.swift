import Foundation

/// What a committed file counts as. Everything else (data, config, prose, lockfiles, vendored and generated files)
/// isn't counted.
public enum LineKind: String, Codable, Sendable, CaseIterable {
    case code, tests, markdown
}

/// Non-blank lines per kind of file. Comment lines count; lines with only whitespace don't.
public struct LineCounts: Codable, Equatable, Sendable {
    public var code: Int
    public var tests: Int
    public var markdown: Int

    public init(code: Int = 0, tests: Int = 0, markdown: Int = 0) {
        self.code = code
        self.tests = tests
        self.markdown = markdown
    }

    /// Source lines: code and tests. Markdown is kept apart.
    public var total: Int { code + tests }

    public subscript(kind: LineKind) -> Int {
        get {
            switch kind {
            case .code: code
            case .tests: tests
            case .markdown: markdown
            }
        }
        set {
            switch kind {
            case .code: code = newValue
            case .tests: tests = newValue
            case .markdown: markdown = newValue
            }
        }
    }
}

/// Sorts a path into code, tests or Markdown from its name alone, so the same commit always gives the same counts.
/// Code follows GitHub's language bar (Linguist): programming and markup languages, HTML and CSS included; data,
/// config and prose formats such as JSON, YAML, TOML, XML and plain text don't count. Changing these rules needs a
/// new `LineCountSnapshot.currentVersion`, since counts made with other rules can't be compared.
public enum LineClassifier {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdx", "mdown", "mkd", "mkdn"]

    static let codeExtensions: Set<String> = [
        // C family, Apple, JVM, .NET
        "c", "h", "cc", "cpp", "cxx", "c++", "hh", "hpp", "hxx", "h++", "ino", "cu", "cuh", "m", "mm", "swift",
        "java", "kt", "kts", "scala", "sc", "groovy", "gvy", "gradle", "clj", "cljs", "cljc",
        "cs", "csx", "fs", "fsi", "fsx", "vb", "vbs",
        // Systems, scripting and functional languages
        "go", "rs", "zig", "nim", "cr", "py", "pyi", "pyx", "pxd", "pyw", "rb", "rake", "gemspec", "php", "phtml",
        "pl", "pm", "lua", "luau", "r", "jl", "dart", "ex", "exs", "erl", "hrl", "gleam", "hs", "lhs", "ml", "mli",
        "elm", "purs", "el", "lisp", "scm", "rkt", "tcl", "awk", "applescript", "sol", "gd", "vim",
        "f90", "f95", "f03", "f08", "cob", "cbl", "ada", "adb", "ads", "pas",
        // Web
        "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx", "coffee", "vue", "svelte", "astro",
        "html", "htm", "xhtml", "css", "scss", "sass", "less", "styl", "pcss",
        "pug", "jade", "haml", "slim", "hbs", "handlebars", "mustache", "ejs", "erb", "liquid", "njk", "twig",
        "jinja", "jinja2", "j2", "cshtml", "razor", "jsp", "aspx",
        // Shell, build and infrastructure
        "sh", "bash", "zsh", "fish", "ksh", "ps1", "psm1", "bat", "cmd", "sql",
        "tf", "tfvars", "hcl", "nix", "jsonnet", "libsonnet", "bzl", "star", "cmake", "mk", "mak", "make", "dockerfile",
        // Low level and shaders
        "asm", "s", "wat", "glsl", "frag", "vert", "hlsl", "metal", "wgsl",
        // TeX
        "tex", "sty",
    ]

    static let codeFileNames: Set<String> = [
        "dockerfile", "containerfile", "makefile", "gnumakefile", "cmakelists.txt", "justfile",
        "rakefile", "gemfile", "podfile", "vagrantfile", "brewfile", "fastfile", "jenkinsfile",
        "build.bazel", "workspace.bazel", "module.bazel",
    ]

    /// Dependencies and build output checked into the repository; nothing inside them counts.
    static let skippedFolders: Set<String> = [
        "node_modules", "bower_components", "vendor", "third_party", "third-party", "thirdparty", "pods", "carthage",
        ".yarn", "dist",
    ]

    static let generatedSuffixes = [
        ".min.js", ".min.mjs", ".min.cjs", ".min.css", ".pb.go", ".pb.swift", ".pb.h", ".pb.cc", "_pb2.py",
        "_pb2_grpc.py", ".g.dart", ".freezed.dart", ".designer.cs",
    ]

    /// A folder with one of these words in its name holds tests: `tests`, `__tests__`, `ShipwatchCoreTests`, `e2e`.
    static let testFolderWords: Set<String> = [
        "test", "tests", "testing", "spec", "specs", "e2e", "testdata", "testutil", "testutils", "fixtures", "mocks",
    ]
    /// A file with one of these words in its name is a test: `api.test.ts`, `client_test.go`, `test_api.py`, `UserTests.swift`.
    static let testFileWords: Set<String> = ["test", "tests", "spec", "specs"]
    static let testFileNames: Set<String> = ["conftest.py"]

    /// `nil` for files that don't count. `path` is relative to the repository root, with `/` between folders.
    public static func kind(of path: String) -> LineKind? {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        let folders = parts.dropLast()
        guard !folders.contains(where: { skippedFolders.contains($0.lowercased()) }) else { return nil }
        let lowercased = name.lowercased()
        guard !generatedSuffixes.contains(where: lowercased.hasSuffix) else { return nil }
        let pathExtension = lowercased.lastIndex(of: ".").flatMap { dot in
            dot == lowercased.startIndex ? nil : String(lowercased[lowercased.index(after: dot)...])
        }
        if let pathExtension, markdownExtensions.contains(pathExtension) { return .markdown }
        let isCode = pathExtension.map(codeExtensions.contains) == true || codeFileNames.contains(lowercased)
            || lowercased.hasPrefix("dockerfile.")
        guard isCode else { return nil }
        let isTest = testFileNames.contains(lowercased)
            || words(in: name).contains(where: testFileWords.contains)
            || folders.contains { words(in: $0).contains(where: testFolderWords.contains) }
        return isTest ? .tests : .code
    }

    /// Lowercased words split at punctuation and camel case: `XMLParserTests` gives `xml`, `parser`, `tests`.
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if character.isUppercase, let previous = current.last {
                let nextIsLowercase = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLowercase) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }
}

/// One count of a clone's local default branch.
public struct LineCount: Codable, Equatable, Sendable {
    public var date: Date
    public var branch: String
    /// The commit that was counted: counting it again gives the same numbers.
    public var commit: String
    public var counts: LineCounts

    public init(date: Date, branch: String, commit: String, counts: LineCounts) {
        self.date = date
        self.branch = branch
        self.commit = commit
        self.counts = counts
    }
}

/// How much a count changed between two weekly counts.
public struct LineGrowth: Equatable, Sendable {
    public var lines: Int
    /// The change as a percentage of the earlier count, `nil` when that was 0.
    public var percent: Double?

    public init(from old: Int, to new: Int) {
        lines = new - old
        percent = old == 0 ? nil : Double(new - old) / Double(old) * 100
    }
}

/// The weekly report of one repository: this week's count and the one before. Nothing older is kept.
public struct LineCountReport: Codable, Equatable, Sendable {
    public var latest: LineCount
    /// `nil` until the second week.
    public var previous: LineCount?

    public init(latest: LineCount, previous: LineCount? = nil) {
        self.latest = latest
        self.previous = previous
    }

    /// Weeks start on Monday at midnight local time (ISO 8601).
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    /// A new count is due once the latest one is from an earlier week.
    public func isDue(at now: Date, calendar: Calendar = LineCountReport.calendar) -> Bool {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return false }
        return latest.date < weekStart
    }

    /// This week's count becomes the latest, the current latest the one to compare with.
    public func adding(_ count: LineCount) -> LineCountReport {
        LineCountReport(latest: count, previous: latest)
    }

    public func growth(_ kind: KeyPath<LineCounts, Int>) -> LineGrowth? {
        previous.map { LineGrowth(from: $0.counts[keyPath: kind], to: latest.counts[keyPath: kind]) }
    }
}

public enum LineCountError: Error, LocalizedError, Equatable {
    case partialClone

    public var errorDescription: String? {
        switch self {
        case .partialClone: "partial clone: counting would download missing files"
        }
    }
}

/// Counts the non-blank lines of the files committed on a clone's local branch, with `git grep` reading git's
/// object database. Never touches the network, the working tree or any ref, so uncommitted changes and other
/// branches don't count.
public struct LineCounter: Sendable {
    public static let timeout: TimeInterval = 120

    private let git: any GitRunning

    public init(git: any GitRunning) {
        self.git = git
    }

    /// `nil` when the clone has no local `branch`.
    public func count(_ clone: LocalClone, branch: String, date: Date = Date()) throws -> LineCount? {
        guard CloneSyncer.isSafeName(branch) else { throw GitError.commandFailed("unexpected branch name") }
        let directory = clone.path
        let resolved = try git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}"], in: directory)
        guard resolved.succeeded, !resolved.trimmed.isEmpty else { return nil }
        let commit = resolved.trimmed.lowercased()
        // Missing files in a partial clone would be fetched from the remote.
        let partial = try git.run(["config", "--get", "extensions.partialClone"], in: directory)
        if partial.succeeded, !partial.trimmed.isEmpty { throw LineCountError.partialClone }
        let output = try git.run(
            [
                "grep", "--no-color", "--no-textconv", "--no-recurse-submodules", "--count", "--null", "-I",
                "--basic-regexp", "--full-name", "-e", "[^[:space:]]", commit, "--",
            ],
            in: directory,
            timeout: Self.timeout
        )
        // 1 means no file has a non-blank line.
        guard output.status == 0 || output.status == 1 else { throw GitError.commandFailed(output.errorSummary) }
        return LineCount(date: date, branch: branch, commit: commit, counts: Self.tally(output.stdout, commit: commit))
    }

    /// Adds up `git grep --count --null` output for `commit`: `<commit>:<path>\0<lines>\n` per file.
    static func tally(_ output: String, commit: String) -> LineCounts {
        var counts = LineCounts()
        let prefix = Array("\(commit):".utf8)
        let bytes = Array(output.utf8)
        var start = 0
        while start < bytes.count, let nul = bytes[start...].firstIndex(of: 0) {
            let newline = bytes[(nul + 1)...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
            let name = bytes[start..<nul]
            let lines = Int(String(decoding: bytes[(nul + 1)..<newline], as: UTF8.self)) ?? 0
            start = newline + 1
            guard name.starts(with: prefix) else { continue }
            let path = String(decoding: name.dropFirst(prefix.count), as: UTF8.self)
            if let kind = LineClassifier.kind(of: path) { counts[kind] += lines }
        }
        return counts
    }
}

/// The weekly reports of every tracked repository.
public struct LineCountSnapshot: Codable, Equatable, Sendable {
    /// Bump when the format or `LineClassifier`'s rules change: saved counts of other versions are dropped and
    /// every repository starts over from a new first count.
    public static let currentVersion = 1

    public var version: Int
    /// Keyed by `RepoRef.key`.
    public var reports: [String: LineCountReport]

    public init(reports: [String: LineCountReport]) {
        version = Self.currentVersion
        self.reports = reports
    }
}

/// Keeps the weekly line counts on disk, readable only by the user.
public struct LineCountCache: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    private var file: SupportFile { SupportFile(url: url) }

    /// `nil` when nothing was saved yet or the snapshot is from another version.
    public func load() throws -> LineCountSnapshot? {
        try file.load(LineCountSnapshot.self, version: LineCountSnapshot.currentVersion)
    }

    public func save(_ snapshot: LineCountSnapshot) throws {
        try file.save(snapshot)
    }
}
