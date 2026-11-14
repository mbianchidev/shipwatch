import AppKit
import Observation
import ShipwatchCore
import os

let uiLog = Logger(subsystem: "dev.mbianchi.shipwatch", category: "ui")

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case repositories, general, account

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .repositories: "Repositories"
        case .general: "General"
        case .account: "Account"
        }
    }

    var symbol: String {
        switch self {
        case .repositories: "list.bullet"
        case .general: "slider.horizontal.3"
        case .account: "person.crop.circle"
        }
    }
}

public enum Banner: Equatable, Sendable {
    case rateLimited(until: Date)
    case offline(String)
    case error(String)
}

public enum CLIStatus: Equatable, Sendable {
    case unknown
    case notInstalled
    case signedOut(String)
    case signedIn(String)
}

public enum SignInStep: Equatable, Sendable {
    case welcome
    case requesting
    case authorize(code: String, verificationURL: URL, expiresAt: Date)
    case install
    case failed(String)
}

/// Window and app plumbing the model triggers. The app delegate fills these in.
@MainActor
public struct AppActions {
    public var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    public var showSettings: @MainActor (SettingsTab) -> Void = { _ in }
    public var showPopover: @MainActor () -> Void = {}
    public var quit: @MainActor () -> Void = { NSApp.terminate(nil) }

    public init() {}
}

@MainActor
@Observable
public final class AppModel {
    public let prefs: Preferences
    @ObservationIgnored public var actions = AppActions()

    // Data
    public var statuses: [String: RepoStatus] = [:]
    public var lastUpdated: Date?
    public var nextRefresh: Date?
    public var isRefreshing = false
    public var banner: Banner?
    public var rateLimitedUntil: Date?

    // Account
    public var authMethod: AuthMethod?
    public var user: GitHubUser?
    public var installations: [AppInstallation] = []
    public var installationRepoCounts: [Int: Int] = [:]
    public var cliStatus: CLIStatus = .unknown
    public var signInStep: SignInStep = .welcome

    // UI state
    public var expanded: Set<String> = []
    public var showHiddenInMenu = false
    public var pendingRemoval: String?
    public var settingsTab: SettingsTab = .repositories
    public var isAddingRepositories = false
    public var launchAtLogin = false
    public var launchAtLoginError: String?

    @ObservationIgnored private let bundled: AppConfig
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let cli: GitHubCLI
    @ObservationIgnored private let vault: TokenVault
    @ObservationIgnored private let client: GitHubClient
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    public init(
        prefs: Preferences,
        bundled: AppConfig = .bundled,
        store: any TokenStore = KeychainTokenStore(),
        cli: GitHubCLI = GitHubCLI(),
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.prefs = prefs
        self.bundled = bundled
        self.cli = cli
        self.transport = transport
        let vault = TokenVault(store: store, cli: cli, cliEnabled: prefs.cliFallback)
        self.vault = vault
        client = GitHubClient(transport: transport) { try await vault.accessToken() }
    }

    // MARK: Derived state

    public var config: AppConfig {
        bundled.overridden(clientID: prefs.clientIDOverride, appSlug: prefs.appSlugOverride)
    }

    public var cliPath: String? { cli.path }

    public var showsOnboarding: Bool {
        authMethod == nil || signInStep == .install
    }

    /// Rows in the popover: visible repos, plus hidden ones while "Show" is on.
    public var menuRepos: [TrackedRepo] {
        showHiddenInMenu ? prefs.repos.items : prefs.repos.visible
    }

    public var overall: OverallStatus {
        OverallStatus(prefs.repos.visible.compactMap { statuses[$0.id] })
    }

    var anyRunning: Bool {
        prefs.repos.items.contains { statuses[$0.id]?.ciState == .running }
    }

    /// Where the user picks which repositories the GitHub App may read.
    public var manageAccessURL: URL {
        if !config.appSlug.isEmpty { return GitHubLinks.appInstall(slug: config.appSlug) }
        return URL(string: "https://github.com/settings/installations")!
    }

    // MARK: Lifecycle

    public func start() {
        launchAtLogin = LoginItem.isEnabled
        observeWake()
        Task {
            await vault.setDeviceFlow(makeDeviceFlow())
            await vault.setCLIEnabled(prefs.cliFallback)
            do {
                authMethod = try await vault.restore()
            } catch {
                uiLog.error("Saved token could not be read: \(error.localizedDescription, privacy: .public)")
                banner = .error(error.localizedDescription)
            }
            if authMethod != nil {
                await loadAccount()
                await refresh()
            } else {
                await probeCLI()
            }
        }
    }

    public func popoverDidOpen() {
        if authMethod == nil {
            Task { await probeCLI() }
            return
        }
        let stale = lastUpdated.map { Date().timeIntervalSince($0) > 60 } ?? true
        if stale && !isRefreshing { requestRefresh() }
    }

    public func popoverDidClose() {
        pendingRemoval = nil
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self?.requestRefresh(force: true)
            }
        }
    }

    // MARK: Refresh

    public func requestRefresh(force: Bool = false) {
        Task { await refresh(force: force) }
    }

    /// Concurrent calls share the running refresh. `force` queues one more pass so new settings are picked up.
    public func refresh(force: Bool = false) async {
        if let refreshTask {
            if force { refreshAgain = true }
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
        if refreshAgain {
            refreshAgain = false
            await refresh()
            return
        }
        scheduleNextRefresh()
    }

    private func performRefresh() async {
        guard authMethod != nil else { return }
        let refs = prefs.repos.items.map(\.ref)
        guard !refs.isEmpty else {
            statuses = [:]
            lastUpdated = Date()
            banner = nil
            return
        }
        if let until = rateLimitedUntil, until > Date() {
            banner = .rateLimited(until: until)
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let includePrereleases = prefs.includePrereleases
            let batch = try await authorized { try await $0.statuses(for: refs, includePrereleases: includePrereleases) }
            statuses = batch.statuses
            lastUpdated = Date()
            banner = nil
            rateLimitedUntil = nil
            if let limit = batch.rateLimit, limit.remaining < 50 {
                uiLog.notice("GitHub rate limit low: \(limit.remaining) left")
            }
        } catch {
            handleRefreshError(error)
        }
    }

    private func handleRefreshError(_ error: any Error) {
        uiLog.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
        switch error {
        case GitHubError.rateLimited(let resetAt):
            let until = resetAt ?? Date().addingTimeInterval(60)
            rateLimitedUntil = until
            banner = .rateLimited(until: until)
        case GitHubError.network(let message):
            banner = .offline(message)
        case GitHubError.unauthorized, GitHubError.notSignedIn:
            banner = authMethod == nil ? nil : .error(error.localizedDescription)
        default:
            banner = .error(error.localizedDescription)
        }
    }

    public func scheduleNextRefresh() {
        timerTask?.cancel()
        guard authMethod != nil else {
            nextRefresh = nil
            return
        }
        let delay: TimeInterval
        if let until = rateLimitedUntil, until > Date() {
            delay = until.timeIntervalSinceNow + 2
        } else if anyRunning {
            delay = 20
        } else {
            delay = TimeInterval(prefs.refreshMinutes * 60)
        }
        nextRefresh = Date().addingTimeInterval(delay)
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Runs a request; on 401 drops the cached token and tries once more, then re-syncs the auth method.
    private func authorized<T: Sendable>(_ operation: (GitHubClient) async throws -> T) async throws -> T {
        do {
            return try await operation(client)
        } catch GitHubError.unauthorized {
            await vault.discardCurrentToken()
            do {
                return try await operation(client)
            } catch GitHubError.unauthorized {
                await syncAuthMethod()
                throw GitHubError.unauthorized
            }
        }
    }

    private func syncAuthMethod() async {
        let method = await vault.method
        guard method != authMethod else { return }
        authMethod = method
        if method == nil {
            signInStep = .welcome
            timerTask?.cancel()
            nextRefresh = nil
            await probeCLI()
        }
    }

    // MARK: Account

    func loadAccount() async {
        do {
            user = try await authorized { try await $0.currentUser() }
        } catch {
            uiLog.error("Could not load the GitHub user: \(error.localizedDescription, privacy: .public)")
        }
        guard authMethod == .githubApp else {
            installations = []
            installationRepoCounts = [:]
            return
        }
        do {
            installations = try await authorized { try await $0.installations() }
            _ = try await installationListings()
        } catch {
            uiLog.error("Could not load app installations: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func installationListings() async throws -> [RepoListing] {
        var seen = Set<String>()
        var listings: [RepoListing] = []
        var counts: [Int: Int] = [:]
        for installation in installations {
            let repos = try await authorized { try await $0.installationRepositories(installation.id) }
            counts[installation.id] = repos.count
            for repo in repos where seen.insert(repo.id).inserted {
                listings.append(repo)
            }
        }
        installationRepoCounts = counts
        return listings
    }

    /// Repositories the "Add Repositories" sheet offers.
    func repositoryListings() async throws -> [RepoListing] {
        switch authMethod {
        case .githubApp:
            installations = try await authorized { try await $0.installations() }
            return try await installationListings()
        case .githubCLI:
            return try await authorized { try await $0.userRepositories() }
        case nil:
            throw GitHubError.notSignedIn
        }
    }

    public func probeCLI() async {
        guard cli.path != nil else {
            cliStatus = .notInstalled
            return
        }
        do {
            let token = try await cli.token()
            let probe = GitHubClient(transport: transport) { token }
            cliStatus = .signedIn(try await probe.currentUser().login)
        } catch GitHubCLI.CLIError.notInstalled {
            cliStatus = .notInstalled
        } catch {
            cliStatus = .signedOut(error.localizedDescription)
        }
    }

    // MARK: Sign-in

    private func makeDeviceFlow() -> DeviceFlow? {
        config.clientID.isEmpty ? nil : DeviceFlow(clientID: config.clientID, transport: transport)
    }

    /// Re-reads the Client ID after it changes in Settings.
    public func applyConfig() {
        let flow = makeDeviceFlow()
        Task { await vault.setDeviceFlow(flow) }
    }

    public func startSignIn() {
        signInTask?.cancel()
        guard let flow = makeDeviceFlow() else {
            signInStep = .failed(DeviceFlowError.missingClientID.localizedDescription)
            return
        }
        signInStep = .requesting
        signInTask = Task {
            do {
                let code = try await flow.requestCode()
                signInStep = .authorize(
                    code: code.userCode,
                    verificationURL: code.verificationUri,
                    expiresAt: Date().addingTimeInterval(TimeInterval(code.expiresIn))
                )
                let token = try await flow.waitForToken(code)
                await vault.setDeviceFlow(flow)
                try await vault.signIn(with: token)
                authMethod = .githubApp
                banner = nil
                await loadAccount()
                signInStep = installations.isEmpty ? .install : .welcome
                actions.showPopover()
                await refresh(force: true)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                uiLog.error("Sign-in failed: \(error.localizedDescription, privacy: .public)")
                signInStep = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signInStep = .welcome
    }

    public func copyCodeAndOpenGitHub(code: String, url: URL) {
        copyToPasteboard(code)
        actions.openURL(url)
    }

    public func finishInstall() {
        signInStep = .welcome
        Task {
            await loadAccount()
            await refresh(force: true)
        }
    }

    public func useCLI() {
        setCLIFallback(true)
    }

    public func setCLIFallback(_ enabled: Bool) {
        prefs.cliFallback = enabled
        Task {
            await vault.setCLIEnabled(enabled)
            let method = await vault.method
            let changed = method != authMethod
            authMethod = method
            if method == nil {
                clearAccount()
                await probeCLI()
            } else if changed {
                banner = nil
                await loadAccount()
                await refresh(force: true)
            }
        }
    }

    public func signOut() {
        signInTask?.cancel()
        timerTask?.cancel()
        prefs.cliFallback = false
        Task {
            do {
                try await vault.signOut()
            } catch {
                uiLog.error("Sign-out could not remove the token: \(error.localizedDescription, privacy: .public)")
                banner = .error(error.localizedDescription)
            }
            authMethod = nil
            clearAccount()
            await probeCLI()
        }
    }

    private func clearAccount() {
        user = nil
        installations = []
        installationRepoCounts = [:]
        statuses = [:]
        lastUpdated = nil
        nextRefresh = nil
        rateLimitedUntil = nil
        signInStep = .welcome
        timerTask?.cancel()
    }

    // MARK: Repositories

    public func status(for repo: TrackedRepo) -> RepoStatus? {
        statuses[repo.id]
    }

    public func addRepositories(_ refs: [RepoRef]) {
        guard prefs.repos.add(refs) > 0 else { return }
        requestRefresh(force: true)
    }

    public func removeRepository(_ id: TrackedRepo.ID) {
        prefs.repos.remove(id)
        statuses[id] = nil
        expanded.remove(id)
        if pendingRemoval == id { pendingRemoval = nil }
    }

    public func setHidden(_ id: TrackedRepo.ID, _ hidden: Bool) {
        prefs.repos.setHidden(id, hidden)
        if hidden { expanded.remove(id) }
    }

    public func move(_ id: TrackedRepo.ID, by offset: Int) {
        prefs.repos.moveVisible(id, by: offset)
    }

    public func toggleExpanded(_ id: TrackedRepo.ID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    public func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func open(_ url: URL) {
        actions.openURL(url)
    }

    public func showAddRepositories() {
        isAddingRepositories = true
        actions.showSettings(.repositories)
    }

    // MARK: Settings

    public func setRefreshMinutes(_ minutes: Int) {
        prefs.refreshMinutes = minutes
        scheduleNextRefresh()
    }

    public func setIncludePrereleases(_ include: Bool) {
        prefs.includePrereleases = include
        requestRefresh(force: true)
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            launchAtLoginError = nil
        } catch {
            uiLog.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = LoginItem.isEnabled
    }

    /// Turns launch at login on the first time Shipwatch runs from its app bundle.
    public func configureLoginItemDefault() {
        guard LoginItem.isAvailable, !prefs.loginItemConfigured else { return }
        prefs.loginItemConfigured = true
        setLaunchAtLogin(true)
    }
}
