import Foundation
import ServiceManagement

/// Launch at login through `SMAppService`. Only works from an app bundle, not from `swift run`.
enum LoginItem {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static func set(_ enabled: Bool) throws {
        guard isAvailable else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
