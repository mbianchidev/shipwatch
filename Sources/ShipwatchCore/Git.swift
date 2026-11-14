import Foundation

/// The result of one `git` invocation. A non-zero status is data, not an error: callers decide what it means.
public struct GitOutput: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
    public var trimmed: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The first meaningful line of the error output, for showing to the user.
    public var errorSummary: String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let line = lines.first { !$0.isEmpty && !$0.lowercased().hasPrefix("hint:") } ?? ""
        let text = line.hasPrefix("fatal: ") ? String(line.dropFirst(7)) : line
        return text.isEmpty ? "git exited with status \(status)" : text
    }
}

public enum GitError: Error, LocalizedError, Equatable {
    case notInstalled
    case launchFailed(String)
    case timedOut(seconds: Int)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Git not found. Install it with `brew install git` or `xcode-select --install`."
        case .launchFailed(let detail):
            "Could not run git: \(detail)"
        case .timedOut(let seconds):
            "git did not finish within \(seconds) s"
        case .commandFailed(let message):
            message
        }
    }
}

/// Runs git in a directory. Tests substitute a fake; the app uses `ProcessGit`.
public protocol GitRunning: Sendable {
    func run(_ arguments: [String], in directory: URL, environment: [String: String], timeout: TimeInterval) throws -> GitOutput
}

extension GitRunning {
    public func run(_ arguments: [String], in directory: URL, timeout: TimeInterval = 30) throws -> GitOutput {
        try run(arguments, in: directory, environment: [:], timeout: timeout)
    }

    /// Like `run`, but a non-zero exit throws `GitError.commandFailed` with git's message.
    @discardableResult
    public func checked(
        _ arguments: [String], in directory: URL, environment: [String: String] = [:], timeout: TimeInterval = 30
    ) throws -> GitOutput {
        let output = try run(arguments, in: directory, environment: environment, timeout: timeout)
        guard output.succeeded else { throw GitError.commandFailed(output.errorSummary) }
        return output
    }
}

/// Runs the real git binary without ever prompting: no terminal, no credential dialogs, no editor.
public struct ProcessGit: GitRunning {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Finds git without touching `/usr/bin/git` when no developer tools are installed:
    /// that stub opens the "install command line developer tools" dialog.
    public static func locate(fileManager: FileManager = .default) -> ProcessGit? {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileManager.isExecutableFile(atPath: path) {
            return ProcessGit(executable: URL(fileURLWithPath: path))
        }
        if developerToolsInstalled(), fileManager.isExecutableFile(atPath: "/usr/bin/git") {
            return ProcessGit(executable: URL(fileURLWithPath: "/usr/bin/git"))
        }
        return nil
    }

    static func developerToolsInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func baseEnvironment(_ inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited
        // Apps started from Finder get a minimal PATH; hooks, LFS and credential helpers live in Homebrew.
        let path = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"].filter { !path.contains($0) }
        environment["PATH"] = (extra + path).joined(separator: ":")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GCM_INTERACTIVE"] = "never"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["GIT_EDITOR"] = "true"
        environment["GIT_MERGE_AUTOEDIT"] = "no"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        return environment
    }

    public func run(_ arguments: [String], in directory: URL, environment: [String: String], timeout: TimeInterval) throws -> GitOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = Self.baseEnvironment().merging(environment) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        // Files, not pipes: no reader threads that a busy thread pool can starve, no buffer to fill, and the
        // output is complete once git exits even if a background child (ssh, a credential helper) keeps the descriptors.
        let output = try CaptureFile()
        let errors = try CaptureFile()
        process.standardOutput = output.handle
        process.standardError = errors.handle

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw GitError.launchFailed(error.localizedDescription)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            throw GitError.timedOut(seconds: Int(timeout))
        }
        return GitOutput(status: process.terminationStatus, stdout: try output.contents(), stderr: try errors.contents())
    }
}

/// An already unlinked temporary file: the open handle keeps it alive and nothing is left behind.
private final class CaptureFile {
    let handle: FileHandle

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shipwatch-git-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw GitError.launchFailed("could not create a temporary file in \(url.deletingLastPathComponent().path)")
        }
        do {
            handle = try FileHandle(forUpdating: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw GitError.launchFailed("could not open a temporary file: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: url)
    }

    func contents() throws -> String {
        do {
            try handle.seek(toOffset: 0)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch {
            throw GitError.commandFailed("could not read git output: \(error.localizedDescription)")
        }
    }

    deinit {
        try? handle.close()
    }
}
