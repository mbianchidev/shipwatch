import Darwin
import Foundation
import os
import ShipwatchUpdate

/// Swaps a staged Shipwatch.app into place once the running app has quit, then confirms the new app starts.
/// Usage: ShipwatchUpdateHelper <transaction.json> <parent-pid>
enum UpdateHelper {
    private static let logger = Logger(subsystem: ShipwatchBundle.identifier, category: "update")

    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        fputs("[ShipwatchUpdateHelper] \(message)\n", stderr)
    }

    static func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        fputs("[ShipwatchUpdateHelper] \(message)\n", stderr)
    }

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 3, let parentPID = Int32(arguments[2]), parentPID > 1, parentPID == getppid() else {
            logError("Usage: ShipwatchUpdateHelper <transaction.json> <parent-pid>")
            return 2
        }
        var update: AppBundleUpdate?
        var ready = false
        var parentExited = false
        var lockFD: Int32 = -1
        defer { if lockFD >= 0 { close(lockFD) } }

        do {
            let prepared = try AppBundleUpdate.readManifest(at: URL(fileURLWithPath: arguments[1]))
            update = prepared
            try FileManager.default.createDirectory(
                at: ShipwatchBundle.supportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            lockFD = open(ShipwatchBundle.lockURL.path, O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                throw AppBundleUpdateError.invalid("Another update is running, or its lock could not be opened.")
            }
            try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8))
            ready = true
            try AppBundleUpdate.waitForProcessExit(pid: parentPID)
            parentExited = true
            try prepared.install(relaunch: {
                try AppBundleRelauncher.launchAndConfirm(
                    bundleURL: prepared.destination,
                    version: prepared.version,
                    directory: prepared.directory,
                    onConfirmed: {
                        try AppBundleUpdateResult(version: prepared.version, errorMessage: nil)
                            .write(to: AppBundleUpdateResult.defaultURL)
                    }
                )
            }, log: logError)
            log("Installed Shipwatch \(prepared.version) at \(prepared.destination.path)")
            return 0
        } catch {
            logError(error.localizedDescription)
            // Before READY the app still owns the staged update and cleans it up itself.
            guard ready, let update else { return 1 }
            recordFailure(error, of: update, relaunch: parentExited)
            return 1
        }
    }

    private static func recordFailure(_ error: Error, of update: AppBundleUpdate, relaunch: Bool) {
        let updateError = error as? AppBundleUpdateError
        if updateError?.preservesBackup != true {
            do { try update.discard() } catch {
                logError("Could not remove the failed staged update: \(error.localizedDescription)")
            }
        }
        do {
            try AppBundleUpdateResult(version: update.version, errorMessage: error.localizedDescription)
                .write(to: AppBundleUpdateResult.defaultURL)
        } catch {
            logError("Could not record the failed update: \(error.localizedDescription)")
        }
        if case .replacementStillRunning = updateError { return }
        guard relaunch else { return }
        do {
            try CommandRunner.run("/usr/bin/open", arguments: [
                "-n", update.destination.path, "--args", "-\(ShipwatchBundle.failedUpdateArgument)", update.version,
            ])
        } catch {
            logError("Could not reopen Shipwatch after the failed update: \(error.localizedDescription)")
        }
    }
}

signal(SIGPIPE, SIG_IGN)
exit(UpdateHelper.run(CommandLine.arguments))
