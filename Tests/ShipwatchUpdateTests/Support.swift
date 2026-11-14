import Foundation
@testable import ShipwatchUpdate

/// Runs `body` with a fresh directory under the package's `.build`, removed afterwards.
func withScratchDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/update-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root.resolvingSymlinksInPath())
}

/// Builds an ad-hoc signed `Shipwatch.app` whose executable is a copy of the universal `/usr/bin/true`.
@discardableResult
func makeSignedApp(in directory: URL, version: String, marker: String) throws -> URL {
    let app = try makeApp(in: directory, version: version, marker: marker) { executable in
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
    }
    try CommandRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", app.path])
    return app
}

/// Builds an unsigned `Shipwatch.app` whose executable is a shell script, for startup confirmation tests.
@discardableResult
func makeScriptApp(in directory: URL, script: String) throws -> URL {
    try makeApp(in: directory, version: "1.0.1", marker: "script") { executable in
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
}

/// Creates a private `.Shipwatch-update-<UUID>` directory beside `bundle`, like `AppBundleUpdate.prepare` does.
func makeStagingDirectory(beside bundle: URL, permissions: Int = 0o700, name: String? = nil) throws -> URL {
    let directory = bundle.deletingLastPathComponent()
        .appendingPathComponent(name ?? UpdateStaging.directoryPrefix + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: permissions]
    )
    return directory
}

func marker(of app: URL) throws -> String {
    try String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
}

private func makeApp(in directory: URL, version: String, marker: String, executable: (URL) throws -> Void) throws -> URL {
    let app = directory.appendingPathComponent(ShipwatchBundle.appName, isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    for folder in ["MacOS", "Resources"] {
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true
        )
    }
    let info: [String: String] = [
        "CFBundleIdentifier": ShipwatchBundle.identifier,
        "CFBundleExecutable": ShipwatchBundle.executableName,
        "CFBundleName": "Shipwatch",
        "CFBundlePackageType": "APPL",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    try Data(marker.utf8).write(to: contents.appendingPathComponent("Resources/marker.txt"))
    try executable(contents.appendingPathComponent("MacOS/\(ShipwatchBundle.executableName)"))
    return app
}
