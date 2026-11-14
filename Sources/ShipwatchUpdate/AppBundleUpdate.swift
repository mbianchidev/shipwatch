import Darwin
import Foundation

package enum AppBundleUpdateError: LocalizedError, Equatable {
    case invalid(String)
    case unsupportedLocation(String)
    case replacement(String)
    case rollback(String)
    case replacementStillRunning(Int32)
    case parentStillRunning

    /// The previous bundle is kept in the staging directory when the swap could not be undone or the new app can't be stopped.
    package var preservesBackup: Bool {
        switch self {
        case .rollback, .replacementStillRunning: true
        default: false
        }
    }

    package var errorDescription: String? {
        switch self {
        case .invalid(let message):
            "Invalid app update: \(message)"
        case .unsupportedLocation(let reason):
            "Shipwatch can't update itself here: \(reason) Move Shipwatch to /Applications or ~/Applications and reopen it."
        case .replacement(let message):
            "App replacement failed: \(message)"
        case .rollback(let message):
            "App rollback failed: \(message)"
        case .replacementStillRunning(let pid):
            "The updated app (PID \(pid)) could not be stopped. The previous app was preserved; rollback and relaunch were not attempted."
        case .parentStillRunning:
            "Shipwatch is still running, so the update was not installed."
        }
    }
}

/// A verified app bundle staged next to the installed one, ready to be swapped in by the update helper.
package struct AppBundleUpdate: Codable {
    package let destination: URL
    package let stagedBundle: URL
    package let version: String
    private let previousVersion: String

    package var directory: URL { stagedBundle.deletingLastPathComponent() }

    /// Copies `source` into a private directory beside `destination`, validating both bundles before and after.
    package static func prepare(from source: URL, replacing destination: URL, version: String) throws -> Self {
        let current = try validateApp(at: destination)
        try validateInstallLocation(destination)
        _ = try validateApp(at: source, expectedVersion: version)

        let destination = destination.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(destination.lastPathComponent)
        let directory = destination.deletingLastPathComponent()
            .appendingPathComponent(UpdateStaging.directoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let update = Self(
            destination: destination,
            stagedBundle: directory.appendingPathComponent(ShipwatchBundle.appName, isDirectory: true),
            version: version,
            previousVersion: current.version
        )
        do {
            try CommandRunner.run("/usr/bin/ditto", arguments: ["--noqtn", source.path, update.stagedBundle.path])
            try update.validate()
            try CommandRunner.run("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", update.stagedBundle.path])
            return update
        } catch {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch let cleanupError {
                throw AppBundleUpdateError.invalid(
                    "\(error.localizedDescription) Staging cleanup also failed: \(cleanupError.localizedDescription)"
                )
            }
            throw error
        }
    }

    package func writeManifest() throws -> URL {
        try validate()
        let url = directory.appendingPathComponent("transaction.json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        return url
    }

    package static func readManifest(at url: URL) throws -> Self {
        let update = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard url.lastPathComponent == "transaction.json",
              url.deletingLastPathComponent().standardizedFileURL == update.directory else {
            throw AppBundleUpdateError.invalid("The update manifest is outside its staging directory.")
        }
        try update.validate()
        return update
    }

    package func validate() throws {
        try validateLayout()
        try Self.validateInstallLocation(destination)
        _ = try Self.validateApp(at: destination, expectedVersion: previousVersion)
        _ = try Self.validateApp(at: stagedBundle, expectedVersion: version)
    }

    /// Swaps the staged bundle in and runs `relaunch`. If that throws, swaps the previous app back.
    package func install(relaunch: () throws -> Void, log: (String) -> Void) throws {
        try validate()
        var preserveBackup = false
        defer {
            if !preserveBackup {
                do { try discard() } catch {
                    log("Update staging cleanup failed at \(directory.path): \(error.localizedDescription)")
                }
            }
        }

        try swapBundles()
        do {
            try relaunch()
        } catch {
            if let updateError = error as? AppBundleUpdateError, case .replacementStillRunning = updateError {
                preserveBackup = true
                log("The updated app is still running; the previous app was preserved at \(stagedBundle.path).")
                throw updateError
            }
            do {
                try swapBundles()
            } catch let rollbackError {
                preserveBackup = true
                throw AppBundleUpdateError.rollback(
                    "\(error.localizedDescription) \(rollbackError.localizedDescription) The previous app was preserved at \(stagedBundle.path)."
                )
            }
            throw AppBundleUpdateError.replacement(
                "The updated app did not start, so Shipwatch rolled back to the previous version. \(error.localizedDescription)"
            )
        }
    }

    package func discard() throws {
        if !FileManager.default.fileExists(atPath: directory.path) { return }
        try validateLayout()
        try FileManager.default.removeItem(at: directory)
    }

    package static func waitForProcessExit(pid: Int32, timeout: TimeInterval = 60) throws {
        guard pid > 1, timeout >= 0 else {
            throw AppBundleUpdateError.invalid("The update helper received an invalid parent process or timeout.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if kill(pid, 0) != 0 {
                if errno == ESRCH { return }
                if errno != EPERM {
                    throw AppBundleUpdateError.invalid("Could not inspect the previous Shipwatch process.")
                }
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw AppBundleUpdateError.parentStillRunning
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Refuses locations the current user can't replace in place: translocated, read-only or unwritable.
    package static func validateInstallLocation(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "app" else {
            throw AppBundleUpdateError.unsupportedLocation("it is not running from an app bundle.")
        }
        guard !url.path.contains("/AppTranslocation/") else {
            throw AppBundleUpdateError.unsupportedLocation("macOS is running it from a temporary, read-only location (App Translocation).")
        }
        let values = try url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        guard values.volumeIsReadOnly != true else {
            throw AppBundleUpdateError.unsupportedLocation("it is on a read-only volume.")
        }
        guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: url.path) else {
            throw AppBundleUpdateError.unsupportedLocation("\(url.path) or its folder is not writable by you.")
        }
    }

    private func validateLayout() throws {
        guard destination.isFileURL, stagedBundle.isFileURL,
              destination == destination.standardizedFileURL,
              stagedBundle == stagedBundle.standardizedFileURL,
              destination.pathExtension.lowercased() == "app",
              stagedBundle.lastPathComponent == ShipwatchBundle.appName else {
            throw AppBundleUpdateError.invalid("The staged app is not a private sibling of the installed app.")
        }
        try UpdateStaging.validate(directory: directory, beside: destination)
    }

    /// Exchanges the two bundles atomically, so the installed path always holds a complete app.
    private func swapBundles() throws {
        let status = destination.path.withCString { destinationPath in
            stagedBundle.path.withCString { stagedPath in
                renameatx_np(AT_FDCWD, destinationPath, AT_FDCWD, stagedPath, UInt32(RENAME_SWAP))
            }
        }
        guard status == 0 else {
            throw AppBundleUpdateError.replacement(String(cString: strerror(errno)))
        }
    }

    private static func validateApp(at url: URL, expectedVersion: String? = nil) throws -> Metadata {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard url.pathExtension.lowercased() == "app",
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw AppBundleUpdateError.invalid("\(url.path) is not an app directory, or is a symlink.")
        }
        let metadata: Metadata
        do {
            metadata = try PropertyListDecoder().decode(
                Metadata.self,
                from: Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            )
        } catch {
            throw AppBundleUpdateError.invalid("\(url.path) has no readable Info.plist.")
        }
        guard metadata.identifier == ShipwatchBundle.identifier,
              metadata.packageType == "APPL",
              metadata.executable == ShipwatchBundle.executableName,
              !metadata.version.isEmpty else {
            throw AppBundleUpdateError.invalid("The app identity or executable does not match Shipwatch.")
        }
        if let expectedVersion, metadata.version != expectedVersion {
            throw AppBundleUpdateError.invalid("Expected version \(expectedVersion), found \(metadata.version) at \(url.path).")
        }
        let executable = url.appendingPathComponent("Contents/MacOS/\(ShipwatchBundle.executableName)")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AppBundleUpdateError.invalid("The app executable is missing or not executable.")
        }
        try CommandRunner.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", url.path])
        #if arch(arm64)
        let architecture = CPU_TYPE_ARM64
        #else
        let architecture = CPU_TYPE_X86_64
        #endif
        guard Bundle(url: url)?.executableArchitectures?.contains(where: { $0.int32Value == architecture }) == true else {
            throw AppBundleUpdateError.invalid("The app does not include an executable for this Mac's processor.")
        }
        return metadata
    }

    private struct Metadata: Decodable {
        let identifier: String
        let packageType: String
        let executable: String
        let version: String

        enum CodingKeys: String, CodingKey {
            case identifier = "CFBundleIdentifier"
            case packageType = "CFBundlePackageType"
            case executable = "CFBundleExecutable"
            case version = "CFBundleShortVersionString"
        }
    }
}

/// The private `.Shipwatch-update-<UUID>` directory that holds a staged update next to the installed app.
package enum UpdateStaging {
    package static let directoryPrefix = ".Shipwatch-update-"

    package static func validate(directory: URL, beside bundle: URL) throws {
        let suffix = String(directory.lastPathComponent.dropFirst(directoryPrefix.count))
        guard directory.isFileURL, bundle.isFileURL,
              directory == directory.standardizedFileURL,
              directory.lastPathComponent.hasPrefix(directoryPrefix),
              UUID(uuidString: suffix) != nil,
              directory.deletingLastPathComponent().resolvingSymlinksInPath()
                == bundle.deletingLastPathComponent().resolvingSymlinksInPath() else {
            throw AppBundleUpdateError.invalid("The update directory is not a private sibling of the app.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw AppBundleUpdateError.invalid("The staging directory is not private to the current user.")
        }
    }
}

/// The outcome of the last helper run, written to `LastUpdate.json` for the next launch to read.
package struct AppBundleUpdateResult: Codable, Equatable, Sendable {
    package let version: String
    package let errorMessage: String?

    package init(version: String, errorMessage: String?) {
        self.version = version
        self.errorMessage = errorMessage
    }

    package static var defaultURL: URL {
        ShipwatchBundle.supportDirectory.appendingPathComponent("LastUpdate.json")
    }

    package static func read(from url: URL) throws -> Self? {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    package func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
