import Foundation
import Testing
@testable import ShipwatchUpdate

struct AppBundleUpdateTests {
    private struct LaunchFailed: Error {}

    /// An installed 1.0.0 app in `Installed/` and a mounted 1.0.1 app in `Volume/`.
    private func withApps(_ body: (_ installed: URL, _ mounted: URL) throws -> Void) throws {
        try withScratchDirectory { directory in
            let installed = try makeSignedApp(in: directory.appendingPathComponent("Installed"), version: "1.0.0", marker: "old")
            let mounted = try makeSignedApp(in: directory.appendingPathComponent("Volume"), version: "1.0.1", marker: "new")
            try body(installed, mounted)
        }
    }

    @Test func stagesIntoAPrivateSiblingAndInstallsThroughTheManifest() throws {
        try withApps { installed, mounted in
            let prepared = try AppBundleUpdate.prepare(from: mounted, replacing: installed, version: "1.0.1")
            #expect(prepared.directory.deletingLastPathComponent() == installed.deletingLastPathComponent())
            let permissions = try FileManager.default.attributesOfItem(atPath: prepared.directory.path)[.posixPermissions] as? Int
            #expect(permissions == 0o700)

            let update = try AppBundleUpdate.readManifest(at: prepared.writeManifest())
            var installedMarker: String?
            try update.install(relaunch: { installedMarker = try marker(of: installed) }, log: { Issue.record("\($0)") })
            #expect(installedMarker == "new")
            #expect(try marker(of: installed) == "new")
            #expect(!FileManager.default.fileExists(atPath: update.directory.path))
        }
    }

    @Test func failedRelaunchSwapsThePreviousAppBack() throws {
        try withApps { installed, mounted in
            let update = try AppBundleUpdate.prepare(from: mounted, replacing: installed, version: "1.0.1")
            var installedMarker: String?
            let error = #expect(throws: AppBundleUpdateError.self) {
                try update.install(relaunch: {
                    installedMarker = try marker(of: installed)
                    throw LaunchFailed()
                }, log: { Issue.record("\($0)") })
            }
            #expect(error?.localizedDescription.contains("rolled back") == true)
            #expect(installedMarker == "new")
            #expect(try marker(of: installed) == "old")
            #expect(!FileManager.default.fileExists(atPath: update.directory.path))
        }
    }

    @Test func refusesAMismatchedVersionWithoutLeavingStaging() throws {
        try withApps { installed, mounted in
            #expect(throws: AppBundleUpdateError.self) {
                try AppBundleUpdate.prepare(from: mounted, replacing: installed, version: "1.0.2")
            }
            let siblings = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
            #expect(siblings == [ShipwatchBundle.appName])
        }
    }

    @Test func refusesManifestsOutsideTheirStagingDirectory() throws {
        try withApps { installed, mounted in
            let update = try AppBundleUpdate.prepare(from: mounted, replacing: installed, version: "1.0.1")
            let moved = installed.deletingLastPathComponent().appendingPathComponent("transaction.json")
            try FileManager.default.moveItem(at: update.writeManifest(), to: moved)
            #expect(throws: AppBundleUpdateError.self) { try AppBundleUpdate.readManifest(at: moved) }
            try update.discard()
        }
    }

    @Test func stagingMustBeAPrivateUUIDSibling() throws {
        try withScratchDirectory { directory in
            let app = directory.appendingPathComponent("Apps/Shipwatch.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try UpdateStaging.validate(directory: makeStagingDirectory(beside: app), beside: app)

            let open = try makeStagingDirectory(beside: app, permissions: 0o755)
            #expect(throws: AppBundleUpdateError.self) { try UpdateStaging.validate(directory: open, beside: app) }
            let unnamed = try makeStagingDirectory(beside: app, name: ".Shipwatch-update-backup")
            #expect(throws: AppBundleUpdateError.self) { try UpdateStaging.validate(directory: unnamed, beside: app) }
            let elsewhere = try makeStagingDirectory(beside: directory.appendingPathComponent("Shipwatch.app"))
            #expect(throws: AppBundleUpdateError.self) { try UpdateStaging.validate(directory: elsewhere, beside: app) }
        }
    }

    @Test func refusesTranslocatedOrNonBundleLocations() throws {
        try withScratchDirectory { directory in
            for path in ["AppTranslocation/X/d/Shipwatch.app", "Shipwatch"] {
                let url = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                #expect(throws: AppBundleUpdateError.self) { try AppBundleUpdate.validateInstallLocation(url) }
            }
        }
    }
}

struct AppBundleStartupTests {
    @Test func confirmsAReplacementThatAcknowledgesStartup() throws {
        try withScratchDirectory { directory in
            let app = try makeScriptApp(in: directory, script: """
                printf '{"token":"%s","processIdentifier":%d,"version":"%s","bundleURL":"%s"}' \
                  "$SHIPWATCH_UPDATE_STARTUP_TOKEN" $$ "$SHIPWATCH_UPDATE_STARTUP_VERSION" "$SHIPWATCH_UPDATE_STARTUP_BUNDLE" \
                  > "$SHIPWATCH_UPDATE_STARTUP_FILE.tmp"
                mv "$SHIPWATCH_UPDATE_STARTUP_FILE.tmp" "$SHIPWATCH_UPDATE_STARTUP_FILE"
                exec sleep 30
                """)
            let staging = try makeStagingDirectory(beside: app)
            var confirmed = false
            try AppBundleRelauncher.launchAndConfirm(bundleURL: app, version: "1.0.1", directory: staging, timeout: 10) {
                confirmed = true
            }
            #expect(confirmed)

            let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: staging.appendingPathComponent("startup.json")))
            let pid = try #require((receipt as? [String: Any])?["processIdentifier"] as? Int32)
            #expect(kill(pid, SIGTERM) == 0)
        }
    }

    @Test(arguments: ["exit 0", "exec sleep 30"])
    func rejectsAReplacementThatNeverAcknowledges(script: String) throws {
        try withScratchDirectory { directory in
            let app = try makeScriptApp(in: directory, script: script)
            let staging = try makeStagingDirectory(beside: app)
            #expect(throws: AppBundleUpdateError.self) {
                try AppBundleRelauncher.launchAndConfirm(bundleURL: app, version: "1.0.1", directory: staging, timeout: 1) {
                    Issue.record("A replacement that never acknowledged was confirmed.")
                }
            }
        }
    }

    @Test func acknowledgementMustMatchTheRequest() throws {
        try withScratchDirectory { directory in
            let app = directory.appendingPathComponent("Shipwatch.app")
            let request = AppBundleStartupRequest(directory: try makeStagingDirectory(beside: app), bundleURL: app, version: "1.0.1")
            let received = try #require(try AppBundleStartupRequest.read(from: request.environment))
            #expect(received == request)
            #expect(throws: AppBundleUpdateError.self) { try received.acknowledge(bundleURL: app, version: "1.0.0") }

            try received.acknowledge(bundleURL: app, version: "1.0.1")
            #expect(try request.isAcknowledged(processIdentifier: getpid()))
            #expect(throws: AppBundleUpdateError.self) { try request.isAcknowledged(processIdentifier: getpid() + 1) }
        }
    }
}
