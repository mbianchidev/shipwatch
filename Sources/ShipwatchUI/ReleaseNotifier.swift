import AppKit
import Observation
import ShipwatchCore
@preconcurrency import UserNotifications

/// Key of the release page in a notification's `userInfo`.
private let releaseURLKey = "releaseURL"

/// Posts macOS notifications for new releases. They show the Shipwatch icon, and clicking one opens the release.
/// Needs the app bundle: `UNUserNotificationCenter` throws an exception in a process without a bundle identifier,
/// such as `swift run` or the snapshot tool.
@MainActor
@Observable
public final class ReleaseNotifier {
    public enum Authorization: Equatable, Sendable {
        case unavailable, notDetermined, allowed, denied
    }

    /// More releases at once than this are posted as one summary.
    static let individualLimit = 3

    public private(set) var authorization: Authorization
    /// Opens the release page, or the popover when the notification has none.
    @ObservationIgnored var open: @MainActor (URL?) -> Void = { _ in }
    @ObservationIgnored private var delegate: ClickHandler?
    @ObservationIgnored private let usesSystem: Bool

    public static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    public init() {
        usesSystem = Self.isAvailable
        authorization = usesSystem ? .notDetermined : .unavailable
    }

    /// Stays in `authorization` and never talks to macOS, for screenshots.
    package init(previewing authorization: Authorization) {
        usesSystem = false
        self.authorization = authorization
    }

    private var center: UNUserNotificationCenter? {
        usesSystem ? UNUserNotificationCenter.current() : nil
    }

    func start() {
        guard let center else { return }
        let delegate = ClickHandler { [weak self] url in self?.open(url) }
        self.delegate = delegate
        center.delegate = delegate
        Task { await refreshAuthorization() }
    }

    /// Reads the current choice in System Settings > Notifications.
    public func refreshAuthorization() async {
        guard let center else { return }
        let status = await center.notificationSettings().authorizationStatus
        authorization = switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    /// Asks macOS for permission the first time; later calls only read the current choice.
    public func requestAuthorization() async {
        guard let center else { return }
        if authorization == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                uiLog.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await refreshAuthorization()
    }

    func post(_ releases: [NewRelease]) {
        guard let center, !releases.isEmpty else { return }
        let requests = releases.count > Self.individualLimit
            ? [Self.summary(releases)]
            : releases.map(Self.request)
        for request in requests {
            center.add(request) { error in
                if let error {
                    uiLog.error("Release notification failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    public func postTest() {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Release notifications are on"
        content.body = "Shipwatch shows one like this when a repository you picked publishes a GitHub release."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "test", content: content, trigger: nil)) { error in
            if let error {
                uiLog.error("Test notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func request(_ item: NewRelease) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "\(item.ref.name) \(item.release.tagName)"
        content.subtitle = item.ref.fullName
        content.body = item.release.isPrerelease ? "New pre-release on GitHub" : "New release on GitHub"
        content.sound = .default
        content.threadIdentifier = item.ref.key
        content.userInfo = [releaseURLKey: item.release.url.absoluteString]
        return UNNotificationRequest(identifier: "release:\(item.ref.key):\(item.release.tagName)", content: content, trigger: nil)
    }

    static func summary(_ releases: [NewRelease]) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "\(releases.count) new releases"
        let names = releases.prefix(individualLimit).map { "\($0.ref.name) \($0.release.tagName)" }
        content.body = names.joined(separator: ", ") + (releases.count > individualLimit ? ", and more" : "")
        content.sound = .default
        return UNNotificationRequest(identifier: "releases:\(UUID().uuidString)", content: content, trigger: nil)
    }
}

/// Shows notifications while Shipwatch is in front too, and handles clicks.
private final class ClickHandler: NSObject, UNUserNotificationCenterDelegate {
    private let open: @MainActor (URL?) -> Void

    init(open: @escaping @MainActor (URL?) -> Void) {
        self.open = open
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let link = response.notification.request.content.userInfo[releaseURLKey] as? String
        await open(link.flatMap(URL.init(string:)))
    }
}
