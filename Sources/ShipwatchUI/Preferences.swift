import Foundation
import Observation
import ShipwatchCore

/// User settings, saved to UserDefaults on every change.
@MainActor
@Observable
public final class Preferences {
    public static let refreshChoices = [1, 2, 5, 10, 15]
    public static let updateCheckChoices = [1, 6, 12, 24]

    private enum Key {
        static let repos = "repos"
        static let refreshMinutes = "refreshMinutes"
        static let activityMode = "activityMode"
        static let includePrereleases = "includePrereleases"
        static let showFailingCount = "showFailingCount"
        static let cliFallback = "cliFallback"
        static let clientIDOverride = "clientIDOverride"
        static let appSlugOverride = "appSlugOverride"
        static let loginItemConfigured = "loginItemConfigured"
        static let checkForUpdates = "checkForUpdates"
        static let updateCheckHours = "updateCheckHours"
        static let installUpdatesAutomatically = "installUpdatesAutomatically"
        static let workspacePath = "workspacePath"
        static let excludedFolders = "excludedFolders"
        static let syncClones = "syncClones"
        static let cloneSyncOptOut = "cloneSyncOptOut"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var repos: RepoList {
        didSet { saveRepos() }
    }
    public var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: Key.refreshMinutes) }
    }
    public var activityMode: ActivityMode {
        didSet { defaults.set(activityMode.rawValue, forKey: Key.activityMode) }
    }
    public var includePrereleases: Bool {
        didSet { defaults.set(includePrereleases, forKey: Key.includePrereleases) }
    }
    public var showFailingCount: Bool {
        didSet { defaults.set(showFailingCount, forKey: Key.showFailingCount) }
    }
    public var cliFallback: Bool {
        didSet { defaults.set(cliFallback, forKey: Key.cliFallback) }
    }
    public var clientIDOverride: String {
        didSet { defaults.set(clientIDOverride, forKey: Key.clientIDOverride) }
    }
    public var appSlugOverride: String {
        didSet { defaults.set(appSlugOverride, forKey: Key.appSlugOverride) }
    }
    /// Launch at login is switched on once, on first launch from the app bundle. After that it's the user's call.
    public var loginItemConfigured: Bool {
        didSet { defaults.set(loginItemConfigured, forKey: Key.loginItemConfigured) }
    }
    public var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Key.checkForUpdates) }
    }
    public var updateCheckHours: Int {
        didSet { defaults.set(updateCheckHours, forKey: Key.updateCheckHours) }
    }
    public var installUpdatesAutomatically: Bool {
        didSet { defaults.set(installUpdatesAutomatically, forKey: Key.installUpdatesAutomatically) }
    }
    /// Absolute path of the folder scanned for local clones. Nothing is scanned while it's `nil`.
    public var workspacePath: String? {
        didSet { defaults.set(workspacePath, forKey: Key.workspacePath) }
    }
    /// Absolute paths skipped by the scan, including their subfolders.
    public var excludedFolders: [String] {
        didSet { defaults.set(excludedFolders, forKey: Key.excludedFolders) }
    }
    /// Fast-forward the default branch of local clones after each refresh.
    public var syncClones: Bool {
        didSet { defaults.set(syncClones, forKey: Key.syncClones) }
    }
    /// `TrackedRepo.id`s whose clones are never touched.
    public var cloneSyncOptOut: Set<String> {
        didSet { defaults.set(cloneSyncOptOut.sorted(), forKey: Key.cloneSyncOptOut) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        repos = Self.loadRepos(defaults)
        let minutes = defaults.integer(forKey: Key.refreshMinutes)
        refreshMinutes = Self.refreshChoices.contains(minutes) ? minutes : 2
        activityMode = defaults.string(forKey: Key.activityMode).flatMap(ActivityMode.init(rawValue:)) ?? .lastPush
        includePrereleases = defaults.bool(forKey: Key.includePrereleases)
        showFailingCount = defaults.bool(forKey: Key.showFailingCount)
        cliFallback = defaults.bool(forKey: Key.cliFallback)
        clientIDOverride = defaults.string(forKey: Key.clientIDOverride) ?? ""
        appSlugOverride = defaults.string(forKey: Key.appSlugOverride) ?? ""
        loginItemConfigured = defaults.bool(forKey: Key.loginItemConfigured)
        checkForUpdates = defaults.object(forKey: Key.checkForUpdates) as? Bool ?? true
        let hours = defaults.integer(forKey: Key.updateCheckHours)
        updateCheckHours = Self.updateCheckChoices.contains(hours) ? hours : 6
        installUpdatesAutomatically = defaults.bool(forKey: Key.installUpdatesAutomatically)
        workspacePath = defaults.string(forKey: Key.workspacePath).flatMap { $0.isEmpty ? nil : $0 }
        excludedFolders = defaults.stringArray(forKey: Key.excludedFolders) ?? []
        syncClones = defaults.bool(forKey: Key.syncClones)
        cloneSyncOptOut = Set(defaults.stringArray(forKey: Key.cloneSyncOptOut) ?? [])
    }

    private static func loadRepos(_ defaults: UserDefaults) -> RepoList {
        guard let data = defaults.data(forKey: Key.repos) else { return RepoList() }
        do {
            return try JSONDecoder().decode(RepoList.self, from: data)
        } catch {
            uiLog.error("Saved repository list is unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            return RepoList()
        }
    }

    private func saveRepos() {
        do {
            defaults.set(try JSONEncoder().encode(repos), forKey: Key.repos)
        } catch {
            uiLog.error("Repository list could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
