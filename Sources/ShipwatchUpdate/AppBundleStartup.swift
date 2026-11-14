import Darwin
import Foundation

/// Proof that a freshly installed app really started: the helper passes a token in the environment and the
/// new app writes it back to `startup.json` in the staging directory once its menu bar item is up.
package struct AppBundleStartupRequest: Equatable, Sendable {
    package let token: UUID
    package let receiptURL: URL
    package let bundleURL: URL
    package let version: String

    private static let tokenKey = "SHIPWATCH_UPDATE_STARTUP_TOKEN"
    private static let fileKey = "SHIPWATCH_UPDATE_STARTUP_FILE"
    private static let versionKey = "SHIPWATCH_UPDATE_STARTUP_VERSION"
    private static let bundleKey = "SHIPWATCH_UPDATE_STARTUP_BUNDLE"
    private static var keys: [String] { [tokenKey, fileKey, versionKey, bundleKey] }

    package init(directory: URL, bundleURL: URL, version: String) {
        token = UUID()
        receiptURL = directory.appendingPathComponent("startup.json")
        self.bundleURL = bundleURL
        self.version = version
    }

    private init(token: UUID, receiptURL: URL, bundleURL: URL, version: String) {
        self.token = token
        self.receiptURL = receiptURL
        self.bundleURL = bundleURL
        self.version = version
    }

    package var environment: [String: String] {
        [
            Self.tokenKey: token.uuidString,
            Self.fileKey: receiptURL.path,
            Self.versionKey: version,
            Self.bundleKey: bundleURL.absoluteString,
        ]
    }

    package static func isRequested(in environment: [String: String]) -> Bool {
        keys.contains { environment[$0] != nil }
    }

    package static func read(from environment: [String: String]) throws -> Self? {
        guard isRequested(in: environment) else { return nil }
        guard let rawToken = environment[tokenKey], let token = UUID(uuidString: rawToken),
              let path = environment[fileKey], (path as NSString).isAbsolutePath,
              let version = environment[versionKey], !version.isEmpty,
              let rawBundle = environment[bundleKey], let bundle = URL(string: rawBundle),
              bundle.isFileURL else {
            throw AppBundleUpdateError.invalid("The update startup request is incomplete or invalid.")
        }
        let request = Self(token: token, receiptURL: URL(fileURLWithPath: path), bundleURL: bundle, version: version)
        try request.validate()
        return request
    }

    /// Keeps the token out of processes the app starts later, such as `gh` or a future update helper.
    package static func removeFromProcessEnvironment() {
        for key in keys { unsetenv(key) }
    }

    package func acknowledge(bundleURL: URL, version: String) throws {
        try validate()
        guard self.bundleURL.resolvingSymlinksInPath() == bundleURL.resolvingSymlinksInPath(),
              self.version == version else {
            throw AppBundleUpdateError.invalid("The running app does not match the update startup request.")
        }
        let acknowledgement = Acknowledgement(token: token, processIdentifier: getpid(), version: version, bundleURL: bundleURL)
        try JSONEncoder().encode(acknowledgement).write(to: receiptURL, options: .atomic)
    }

    package func isAcknowledged(processIdentifier: Int32) throws -> Bool {
        let acknowledgement: Acknowledgement
        do {
            acknowledgement = try JSONDecoder().decode(Acknowledgement.self, from: Data(contentsOf: receiptURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
        guard acknowledgement.token == token,
              acknowledgement.processIdentifier == processIdentifier,
              acknowledgement.version == version,
              acknowledgement.bundleURL.resolvingSymlinksInPath() == bundleURL.resolvingSymlinksInPath() else {
            throw AppBundleUpdateError.invalid("The update startup acknowledgement does not match this update.")
        }
        return true
    }

    func validate() throws {
        guard !version.isEmpty, receiptURL.isFileURL,
              receiptURL.lastPathComponent == "startup.json",
              bundleURL.pathExtension.lowercased() == "app" else {
            throw AppBundleUpdateError.invalid("The update startup receipt has an invalid location or version.")
        }
        try UpdateStaging.validate(directory: receiptURL.deletingLastPathComponent(), beside: bundleURL)
    }

    private struct Acknowledgement: Codable {
        let token: UUID
        let processIdentifier: Int32
        let version: String
        let bundleURL: URL
    }
}

/// Starts the swapped-in app and waits until it acknowledges startup, stopping it again if it doesn't.
package enum AppBundleRelauncher {
    package static func launchAndConfirm(
        bundleURL: URL,
        version: String,
        directory: URL,
        timeout: TimeInterval = 30,
        onConfirmed: () throws -> Void
    ) throws {
        guard timeout > 0 else {
            throw AppBundleUpdateError.invalid("The update startup timeout must be positive.")
        }
        let request = AppBundleStartupRequest(directory: directory, bundleURL: bundleURL, version: version)
        try request.validate()
        let process = Process()
        process.executableURL = bundleURL.appendingPathComponent("Contents/MacOS/\(ShipwatchBundle.executableName)")
        process.currentDirectoryURL = bundleURL.deletingLastPathComponent()
        process.environment = ProcessInfo.processInfo.environment.merging(request.environment) { _, update in update }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        do {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var acknowledgedAt: TimeInterval?
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard process.isRunning else {
                    throw AppBundleUpdateError.replacement(
                        "The updated app exited before confirming startup (status \(process.terminationStatus))."
                    )
                }
                if try request.isAcknowledged(processIdentifier: process.processIdentifier) {
                    let now = ProcessInfo.processInfo.systemUptime
                    if acknowledgedAt == nil { acknowledgedAt = now }
                    if let acknowledgedAt, now - acknowledgedAt >= 0.5 {
                        try onConfirmed()
                        guard process.isRunning else {
                            throw AppBundleUpdateError.replacement("The updated app exited during startup confirmation.")
                        }
                        return
                    }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw AppBundleUpdateError.replacement("The updated app did not confirm startup within \(Int(timeout)) seconds.")
        } catch {
            try stopReplacement(process)
            throw error
        }
    }

    private static func stopReplacement(_ process: Process) throws {
        if process.isRunning {
            process.terminate()
            waitForTermination(process)
        }
        if process.isRunning {
            if kill(process.processIdentifier, SIGKILL) != 0, errno != ESRCH {
                throw AppBundleUpdateError.replacementStillRunning(process.processIdentifier)
            }
            waitForTermination(process)
        }
        guard !process.isRunning else {
            throw AppBundleUpdateError.replacementStillRunning(process.processIdentifier)
        }
        process.waitUntilExit()
    }

    private static func waitForTermination(_ process: Process) {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
