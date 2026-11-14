import Foundation

/// Names and locations shared by the app, the update helper and the release tool.
package enum ShipwatchBundle {
    package static let identifier = "dev.mbianchi.shipwatch"
    package static let executableName = "Shipwatch"
    package static let appName = "Shipwatch.app"
    package static let helperName = "ShipwatchUpdateHelper"
    package static let helperPath = "Contents/Helpers/ShipwatchUpdateHelper"
    package static let helperIdentifier = "dev.mbianchi.shipwatch.update-helper"
    /// Passed as `-ShipwatchFailedUpdateVersion <v>` when the helper reopens the previous app after a failed update.
    package static let failedUpdateArgument = "ShipwatchFailedUpdateVersion"

    package static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Shipwatch", isDirectory: true)
    }

    package static var lockURL: URL { supportDirectory.appendingPathComponent("update.lock") }
}
