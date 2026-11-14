import Foundation

/// Which GitHub App Shipwatch signs in with. Release builds bake these into Info.plist;
/// `swift run` reads `SHIPWATCH_CLIENT_ID` and `SHIPWATCH_APP_SLUG` instead. Settings can override both.
public struct AppConfig: Equatable, Sendable {
    public var clientID: String
    public var appSlug: String

    public init(clientID: String = "", appSlug: String = "") {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appSlug = appSlug.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static var bundled: AppConfig {
        let info = Bundle.main.infoDictionary ?? [:]
        let environment = ProcessInfo.processInfo.environment
        func value(_ plistKey: String, _ environmentKey: String) -> String {
            let fromPlist = (info[plistKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return fromPlist.isEmpty ? (environment[environmentKey] ?? "") : fromPlist
        }
        return AppConfig(
            clientID: value("ShipwatchClientID", "SHIPWATCH_CLIENT_ID"),
            appSlug: value("ShipwatchAppSlug", "SHIPWATCH_APP_SLUG")
        )
    }

    /// Non-empty overrides win over the bundled values.
    public func overridden(clientID: String, appSlug: String) -> AppConfig {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = appSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppConfig(clientID: id.isEmpty ? self.clientID : id, appSlug: slug.isEmpty ? self.appSlug : slug)
    }
}
