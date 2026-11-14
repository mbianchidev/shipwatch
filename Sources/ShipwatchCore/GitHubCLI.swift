import Foundation

/// Reads a token from the GitHub CLI (`gh auth token`) on demand. Shipwatch never writes it to disk.
public struct GitHubCLI: Sendable {
    public enum CLIError: Error, LocalizedError, Equatable {
        case notInstalled
        case notSignedIn(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                "GitHub CLI (gh) not found. Install it with `brew install gh`."
            case .notSignedIn(let detail):
                "GitHub CLI isn't signed in. Run `gh auth login`.\(detail.isEmpty ? "" : " (\(detail))")"
            }
        }
    }

    /// Apps launched from Finder get a minimal PATH, so look in the usual install locations first.
    public static let candidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    package typealias Runner = @Sendable (URL, [String]) throws -> String

    private let executable: URL?
    private let runner: Runner

    public init(executable: URL? = GitHubCLI.locate()) {
        self.init(executable: executable, runner: Self.run)
    }

    /// Lets previews and tests stand in for the real `gh` process.
    package init(executable: URL?, runner: @escaping Runner) {
        self.executable = executable
        self.runner = runner
    }

    public var path: String? { executable?.path }

    public static func locate(fileManager: FileManager = .default) -> URL? {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/gh" }
        for path in candidatePaths + pathDirectories where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func token() async throws -> String {
        guard let executable else { throw CLIError.notInstalled }
        let runner = runner
        return try await Task.detached(priority: .utility) {
            try runner(executable, ["auth", "token", "--hostname", "github.com"])
        }.value
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !token.isEmpty else {
            let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError.notSignedIn(detail)
        }
        return token
    }
}
