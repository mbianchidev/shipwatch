import Darwin
import Foundation

/// A private per-attempt directory for the downloaded image and its mount point. The caller removes it when done.
package struct UpdateWorkspace: Sendable {
    package let directory: URL

    package static func create() throws -> Self {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shipwatch-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return Self(directory: directory)
    }

    package var diskImage: URL { directory.appendingPathComponent(UpdateFeed.diskImageName) }
    package var mountPoint: URL { directory.appendingPathComponent("mount", isDirectory: true) }

    package func remove() throws {
        try FileManager.default.removeItem(at: directory)
    }
}

package enum UpdateInstallerError: LocalizedError {
    case helper(String)

    package var errorDescription: String? {
        switch self {
        case .helper(let message): message
        }
    }
}

/// Stages a verified disk image next to the running app and hands the swap to the update helper.
/// Blocks on `hdiutil`, `ditto` and `codesign`, so call it off the main thread.
package enum UpdateInstaller {
    package static func start(
        diskImage: URL,
        mountPoint: URL,
        version: String,
        appURL: URL,
        log: @escaping @Sendable (String) -> Void,
        onHelperFailure: @escaping @Sendable (String) -> Void
    ) throws -> Process {
        try AppBundleUpdate.validateInstallLocation(appURL)
        try FileManager.default.createDirectory(
            at: mountPoint,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var mounted = false
        var update: AppBundleUpdate?
        var handedOff = false
        defer {
            if !handedOff, let update {
                do { try update.discard() } catch {
                    log("Could not remove the staged update at \(update.directory.path): \(error.localizedDescription)")
                }
            }
            if mounted { detach(mountPoint, log: log) }
        }

        try CommandRunner.run("/usr/bin/hdiutil", arguments: [
            "attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, diskImage.path,
        ])
        mounted = true
        let prepared = try AppBundleUpdate.prepare(
            from: mountPoint.appendingPathComponent(ShipwatchBundle.appName),
            replacing: appURL,
            version: version
        )
        update = prepared
        try CommandRunner.run("/usr/bin/hdiutil", arguments: ["detach", "-quiet", mountPoint.path])
        mounted = false

        let helper = prepared.directory.appendingPathComponent(ShipwatchBundle.helperName)
        try FileManager.default.copyItem(at: appURL.appendingPathComponent(ShipwatchBundle.helperPath), to: helper)
        try CommandRunner.run("/usr/bin/codesign", arguments: [
            "--verify", "--strict", "-R=identifier \"\(ShipwatchBundle.helperIdentifier)\"", helper.path,
        ])
        let manifest = try prepared.writeManifest()
        let process = try launchHelper(helper, manifest: manifest, log: log, onFailure: onHelperFailure)
        handedOff = true
        return process
    }

    private static func detach(_ mountPoint: URL, log: (String) -> Void) {
        for arguments in [["detach", "-quiet", mountPoint.path], ["detach", "-quiet", "-force", mountPoint.path]] {
            do {
                try CommandRunner.run("/usr/bin/hdiutil", arguments: arguments)
                return
            } catch {
                log("Could not unmount the update image at \(mountPoint.path): \(error.localizedDescription)")
            }
        }
    }

    private static func launchHelper(
        _ helper: URL,
        manifest: URL,
        log: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws -> Process {
        let readiness = Pipe()
        let process = Process()
        process.executableURL = helper
        process.arguments = [manifest.path, String(getpid())]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = readiness
        process.standardError = FileHandle.standardError
        try process.run()
        do {
            try waitUntilReady(readiness.fileHandleForReading)
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        // Set only after READY, so an early exit is reported once, by the thrown error.
        process.terminationHandler = { task in
            guard task.terminationStatus != 0 else { return }
            let message = "The update helper stopped with status \(task.terminationStatus). Shipwatch was not updated."
            log(message)
            onFailure(message)
        }
        return process
    }

    private static func waitUntilReady(_ handle: FileHandle) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let status = poll(&descriptor, 1, 1_000)
            if status > 0 {
                guard handle.readData(ofLength: 6) == Data("READY\n".utf8) else {
                    throw UpdateInstallerError.helper("The update helper could not prepare the restart. Shipwatch was not updated.")
                }
                return
            }
            if status < 0, errno != EINTR {
                throw UpdateInstallerError.helper("Could not talk to the update helper: \(String(cString: strerror(errno)))")
            }
        }
        throw UpdateInstallerError.helper("The update helper did not start within 30 seconds. Shipwatch was not updated.")
    }
}
