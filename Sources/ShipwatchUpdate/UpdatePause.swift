import Foundation

/// Decides whether a release may be installed without asking, after an earlier update failed.
/// A failed version is only installed manually; newer versions still install automatically.
package struct UpdatePause: Equatable, Sendable {
    /// Why automatic installs are paused, shown to the user.
    private var message: String?
    private var pausedVersion: String?
    private var pausesAll = false

    package init() {}

    /// Pauses only `version`, after it failed to install.
    package init(failedVersion version: String, message: String) {
        pause(version, message: message)
    }

    /// Pauses every version until the user installs one manually.
    package init(pausingAll message: String) {
        self.message = message
        pausesAll = true
    }

    /// Reads `LastUpdate.json` and the `-ShipwatchFailedUpdateVersion` launch argument the helper passes on rollback.
    /// Failures of `currentVersion` or older are ignored: that version or a newer one is already installed.
    package init(resultURL: URL, failedVersionArgument: String?, currentVersion: UpdateVersion) {
        let isNewer = { (text: String) in UpdateVersion(text).map { $0 > currentVersion } ?? false }
        do {
            if let result = try AppBundleUpdateResult.read(from: resultURL), let error = result.errorMessage,
               isNewer(result.version) {
                self.init(failedVersion: result.version, message: "Updating to \(result.version) failed: \(error)")
            } else {
                self.init()
            }
        } catch {
            self.init(pausingAll: "Shipwatch could not read its last update result, so automatic installs are paused. Use Install to update manually.")
        }
        if let version = failedVersionArgument.flatMap({ UpdateVersion($0) })?.description, isNewer(version),
           pausedVersion != version {
            pausedVersion = version
            if !pausesAll {
                message = "Updating to \(version) failed, so Shipwatch reopened the previous version."
            }
        }
    }

    /// Pauses `version` instead of an earlier failed one. A pause on every version stays in place.
    package mutating func pause(_ version: String, message: String) {
        pausedVersion = version
        self.message = message
    }

    package func allowsAutomaticInstall(of version: UpdateVersion) -> Bool {
        !pausesAll && pausedVersion != version.description
    }

    /// `message` while it concerns `release`, or while no release is on offer. A newer release than the failed one hides it.
    package func message(offering release: UpdateVersion?) -> String? {
        guard let release else { return message }
        return allowsAutomaticInstall(of: release) ? nil : message
    }
}
