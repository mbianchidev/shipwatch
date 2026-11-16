import AppKit
import Observation
import ShipwatchCore
import ShipwatchUpdate
import os

let uiLog = Logger(subsystem: "dev.mbianchi.shipwatch", category: "ui")

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case repositories, workspace, general, account

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .repositories: "Repositories"
        case .workspace: "Workspace"
        case .general: "General"
        case .account: "Account"
        }
    }

    var symbol: String {
        switch self {
        case .repositories: "list.bullet"
        case .workspace: "folder"
        case .general: "slider.horizontal.3"
        case .account: "person.crop.circle"
        }
    }
}

/// What the group sheet in Settings edits.
public enum GroupEditor: Identifiable, Hashable, Sendable {
    /// A new group, starting with these repositories.
    case new([TrackedRepo.ID])
    case edit(RepoGroup.ID)

    public var id: String {
        switch self {
        case .new: "new"
        case .edit(let id): RepoGroup.entryID(id)
        }
    }
}

public enum Banner: Equatable, Sendable {
    case rateLimited(until: Date)
    case offline(String)
    case error(String)
}

/// What the summary chips narrow the list to.
public enum RepoFilter: Hashable, Sendable {
    case ci(CIState)
    /// Repositories with at least one open Dependabot pull request.
    case dependabot
    /// Repositories with at least one open Dependabot, code scanning or secret scanning alert.
    case securityAlerts
    /// Repositories with at least one open pull request waiting for your review.
    case reviewRequests

    func matches(_ status: RepoStatus?) -> Bool {
        guard let status, status.problem == nil else { return false }
        switch self {
        case .ci(let state): return status.ciState == state
        case .dependabot: return status.dependabotPullRequests > 0
        case .securityAlerts: return status.securityAlerts?.hasAlerts == true
        case .reviewRequests: return (status.reviewRequests ?? 0) > 0
        }
    }
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
    public var revealInFinder: @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    public var showSettings: @MainActor (SettingsTab) -> Void = { _ in }
    public var showPopover: @MainActor () -> Void = {}
    public var quit: @MainActor () -> Void = { NSApp.terminate(nil) }

    public init() {}
}

@MainActor
@Observable
public final class AppModel {
    public let prefs: Preferences
    let updater: Updater
    public let workspace: WorkspaceModel
    public let notifier: ReleaseNotifier
    @ObservationIgnored public var actions = AppActions()

    // Data
    public var statuses: [String: RepoStatus] = [:]
    public var lastUpdated: Date?
    public var nextRefresh: Date?
    public var isRefreshing = false
    /// How long the last successful refresh took.
    public var lastRefreshDuration: TimeInterval?
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
    /// Set by the summary chips: only matching repositories are listed.
    public var filter: RepoFilter?
    public var pendingRemoval: String?
    public var settingsTab: SettingsTab = .repositories
    public var isAddingRepositories = false
    public var groupEditor: GroupEditor?
    /// Groups whose repositories Settings leaves out, apart from the menu's own expanded state.
    public var collapsedSettingsGroups: Set<RepoGroup.ID> = []
    public var launchAtLogin = false
    public var launchAtLoginError: String?
    /// Launch at login needs the app bundle; a bare `swift run` binary cannot register.
    public var loginItemAvailable = LoginItem.isAvailable

    @ObservationIgnored private let bundled: AppConfig
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let cli: GitHubCLI
    @ObservationIgnored private let vault: TokenVault
    @ObservationIgnored private let client: GitHubClient
    @ObservationIgnored private let statusCache: StatusCache?
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
        transport: any HTTPTransport = URLSessionTransport(),
        git: (any GitRunning)? = ProcessGit.locate(),
        statusCache: StatusCache? = .standard,
        notifier: ReleaseNotifier = ReleaseNotifier()
    ) {
        self.prefs = prefs
        updater = Updater(prefs: prefs)
        workspace = WorkspaceModel(prefs: prefs, git: git)
        self.notifier = notifier
        self.bundled = bundled
        self.cli = cli
        self.transport = transport
        let vault = TokenVault(store: store, cli: cli, cliEnabled: prefs.cliFallback)
        self.vault = vault
        client = GitHubClient(transport: transport) { try await vault.accessToken() }
        self.statusCache = statusCache
        notifier.open = { [weak self] url in
            if let url { self?.open(url) } else { self?.actions.showPopover() }
        }
    }

    // MARK: Derived state

    public var config: AppConfig {
        bundled.overridden(clientID: prefs.clientIDOverride, appSlug: prefs.appSlugOverride)
    }

    public var cliPath: String? { cli.path }

    public var showsOnboarding: Bool {
        authMethod == nil || signInStep == .install
    }

    /// Rows in the popover: visible repos, plus hidden ones while "Show" is on, of the chosen owner, narrowed by
    /// the filter.
    public var menuRepos: [TrackedRepo] {
        let repos = prefs.repos.items.filter(isListed)
        guard let filter else { return repos }
        return repos.filter { filter.matches(statuses[$0.id]) }
    }

    /// `menuRepos` as top-level popover rows, grouped and in the chosen order.
    public var menuEntries: [RepoListEntry] {
        let shown = Set(menuRepos.map(\.id))
        let mode = prefs.activityMode
        return prefs.repos.entries { shown.contains($0.id) }
            .sorted(by: prefs.menuSort) { statuses[$0.id]?.lastActivity(mode) }
    }

    func isShownInMenu(_ repo: TrackedRepo) -> Bool {
        showHiddenInMenu || !repo.hidden
    }

    /// The `RepoRef.ownerKey` the popover is narrowed to, while a tracked repository still has that owner.
    public var menuOwner: String? {
        guard let owner = prefs.menuOwner, prefs.repos.items.contains(where: { $0.ref.ownerKey == owner }) else { return nil }
        return owner
    }

    /// Choices of the popover's owner menu: owners of the shown repositories, and the chosen one.
    public var menuOwners: [RepoOwner] {
        let chosen = menuOwner
        return prefs.repos.owners { isShownInMenu($0) || $0.ref.ownerKey == chosen }
    }

    private func isOfMenuOwner(_ repo: TrackedRepo) -> Bool {
        menuOwner.map { repo.ref.ownerKey == $0 } ?? true
    }

    /// Listed in the popover before the summary chips narrow it: shown, and of the chosen owner.
    func isListed(_ repo: TrackedRepo) -> Bool {
        isShownInMenu(repo) && isOfMenuOwner(repo)
    }

    /// Visible repositories of the chosen owner, which the summary chips count.
    private var menuVisible: [TrackedRepo] {
        prefs.repos.visible.filter(isOfMenuOwner)
    }

    /// Visible repositories of the chosen owner the filter would list.
    public func visibleCount(_ filter: RepoFilter) -> Int {
        menuVisible.count { filter.matches(statuses[$0.id]) }
    }

    /// While a filter is on, groups list their matching members.
    public func isExpanded(_ group: RepoGroup) -> Bool {
        filter != nil || group.isExpanded
    }

    /// Every visible repository, whatever owner the popover shows, for the menu bar icon.
    public var overall: OverallStatus {
        OverallStatus(prefs.repos.visible.compactMap { statuses[$0.id] })
    }

    /// Visible repositories of the chosen owner, for the summary chips.
    public var menuOverall: OverallStatus {
        OverallStatus(menuVisible.compactMap { statuses[$0.id] })
    }

    var anyActive: Bool {
        prefs.repos.items.contains { [CIState.running, .queued].contains(statuses[$0.id]?.ciState ?? .none) }
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
        notifier.start()
        Task { await workspace.rescan() }
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
                restoreCachedStatuses()
                await loadAccount()
                // A relaunch shortly after a refresh, such as for an update, waits for the next one on schedule.
                if let age = lastUpdated.map({ Date().timeIntervalSince($0) }), age >= 0, age < refreshDelay {
                    scheduleNextRefresh(elapsed: age)
                } else {
                    await refresh()
                }
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
        filter = nil
    }

    /// Lists only matching repositories, or everything again when that filter is already on.
    public func toggleFilter(_ filter: RepoFilter) {
        self.filter = self.filter == filter ? nil : filter
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
        let started = Date()
        do {
            let includePrereleases = prefs.includePrereleases
            let securityAlerts = prefs.showSecurityAlerts
            let mine = mineScope
            let reviews = reviewScope
            let batch = try await authorized {
                try await $0.statuses(
                    for: refs, includePrereleases: includePrereleases, securityAlerts: securityAlerts, mine: mine, reviews: reviews
                )
            }
            let previous = statuses, previousAt = lastUpdated
            statuses = followRenames(batch.statuses)
            notifyNewReleases(previous: previous, previousAt: previousAt)
            lastUpdated = Date()
            let took = Date().timeIntervalSince(started)
            lastRefreshDuration = took
            uiLog.info("Refreshed \(refs.count) repositories in \(RelativeTime.duration(took), privacy: .public)")
            banner = nil
            rateLimitedUntil = nil
            saveStatuses()
            let fresh = statuses
            Task { await workspace.afterRefresh(statuses: fresh) }
            if let limit = batch.rateLimit, limit.remaining < 50 {
                uiLog.notice("GitHub rate limit low: \(limit.remaining) left")
            }
        } catch {
            handleRefreshError(error)
        }
    }

    /// Points tracked repositories that GitHub now reports under another name or owner at that name, keeping their
    /// place, group, visibility and clone settings, and rekeys `fresh` to match. GitHub's search doesn't follow
    /// renames, so a renamed repository gets one more pass to count its Dependabot pull requests.
    private func followRenames(_ fresh: [String: RepoStatus]) -> [String: RepoStatus] {
        var result = fresh
        var repos = prefs.repos
        for item in prefs.repos.items {
            guard let status = fresh[item.id], status.problem == nil, status.ref != item.ref,
                  repos.rename(item.id, to: status.ref)
            else { continue }
            let old = item.id, new = status.ref.key
            uiLog.notice("\(item.ref.fullName, privacy: .private) is now \(status.ref.fullName, privacy: .private) on GitHub")
            guard old != new else { continue }
            result[old] = nil
            if result[new] == nil { result[new] = status }
            if expanded.remove(old) != nil { expanded.insert(new) }
            if pendingRemoval == old { pendingRemoval = nil }
            if prefs.cloneSyncOptOut.remove(old) != nil { prefs.cloneSyncOptOut.insert(new) }
            if prefs.releaseNotifications.remove(old) != nil { prefs.releaseNotifications.insert(new) }
            if prefs.onlyMineRepos.remove(old) != nil { prefs.onlyMineRepos.insert(new) }
            refreshAgain = true
        }
        if repos != prefs.repos { prefs.repos = repos }
        return result
    }

    /// Posts a notification for each release published since the previous refresh by a repository with the bell on.
    private func notifyNewReleases(previous: [String: RepoStatus], previousAt: Date?) {
        guard !prefs.releaseNotifications.isEmpty else { return }
        let found = ReleaseWatch.newReleases(
            previous: previous, previousAt: previousAt, current: statuses, watched: prefs.releaseNotifications
        )
        guard !found.isEmpty else { return }
        for item in found {
            uiLog.notice("\(item.ref.fullName, privacy: .private) released \(item.release.tagName, privacy: .private)")
        }
        notifier.post(found)
    }

    // MARK: Status cache

    /// Lists the statuses of the last refresh before this launch, so rows don't show "Loading…" until the first
    /// refresh is done.
    private func restoreCachedStatuses() {
        guard let statusCache, statuses.isEmpty else { return }
        do {
            guard let snapshot = try statusCache.load() else { return }
            let tracked = Set(prefs.repos.items.map(\.id))
            var restored = snapshot.statuses.filter { tracked.contains($0.key) }
            if !prefs.showSecurityAlerts {
                for key in restored.keys { restored[key]?.securityAlerts = nil }
            }
            guard !restored.isEmpty else { return }
            statuses = restored
            lastUpdated = snapshot.savedAt
        } catch {
            uiLog.error("Cached statuses are unreadable, loading fresh ones: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveStatuses() {
        guard let statusCache, let lastUpdated else { return }
        do {
            try statusCache.save(StatusSnapshot(savedAt: lastUpdated, statuses: statuses))
        } catch {
            uiLog.error("Statuses could not be cached: \(error.localizedDescription, privacy: .public)")
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

    /// Time between automatic refreshes right now.
    private var refreshDelay: TimeInterval {
        if let until = rateLimitedUntil, until > Date() { return until.timeIntervalSinceNow + 2 }
        return anyActive ? 20 : TimeInterval(prefs.refreshMinutes * 60)
    }

    /// `elapsed` is how long ago the data was fetched, when that wasn't just now.
    public func scheduleNextRefresh(elapsed: TimeInterval = 0) {
        timerTask?.cancel()
        guard authMethod != nil else {
            nextRefresh = nil
            return
        }
        let delay = max(refreshDelay - elapsed, 0)
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
        do {
            try statusCache?.remove()
        } catch {
            uiLog.error("Cached statuses could not be removed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Repositories

    public func status(for repo: TrackedRepo) -> RepoStatus? {
        statuses[repo.id]
    }

    public func addRepositories(_ refs: [RepoRef]) {
        workspace.stopIgnoring(refs)
        guard prefs.repos.add(refs) > 0 else { return }
        requestRefresh(force: true)
        Task { await workspace.rescan() }
    }

    public func removeRepository(_ id: TrackedRepo.ID) {
        removeRepositories([id])
    }

    /// Stops tracking the repositories. Nothing changes on GitHub, and local clones stay on disk. `ignoring` also
    /// keeps them out of "Track N Found Here".
    public func removeRepositories(_ ids: [TrackedRepo.ID], ignoring: Bool = false) {
        var repos = prefs.repos
        for id in ids { repos.remove(id) }
        guard repos != prefs.repos else { return }
        if ignoring { workspace.ignore(prefs.repos.items.filter { ids.contains($0.id) }.map(\.ref)) }
        prefs.repos = repos
        for id in ids {
            statuses[id] = nil
            expanded.remove(id)
        }
        if !prefs.releaseNotifications.isDisjoint(with: ids) { prefs.releaseNotifications.subtract(ids) }
        if !prefs.onlyMineRepos.isDisjoint(with: ids) { prefs.onlyMineRepos.subtract(ids) }
        if let pendingRemoval, ids.contains(pendingRemoval) { self.pendingRemoval = nil }
        if prefs.menuOwner != nil, menuOwner == nil { prefs.menuOwner = nil }
        workspace.untrack(Set(ids))
        Task { await workspace.rescan() }
    }

    /// Whether the repository counts only the issues and pull requests assigned to you and the runs you triggered.
    public func isOnlyMine(_ id: TrackedRepo.ID) -> Bool {
        prefs.onlyMine || prefs.onlyMineRepos.contains(id)
    }

    public func setOnlyMine(_ ids: [TrackedRepo.ID], _ enabled: Bool) {
        if enabled { prefs.onlyMineRepos.formUnion(ids) } else { prefs.onlyMineRepos.subtract(ids) }
        requestRefresh(force: true)
    }

    public func setOnlyMineEverywhere(_ enabled: Bool) {
        prefs.onlyMine = enabled
        requestRefresh(force: true)
    }

    /// What the next refresh limits to you. Needs the signed-in login; without it everything is counted.
    private var mineScope: MineScope? {
        let keys = Set(prefs.repos.items.map(\.id).filter(isOnlyMine))
        guard !keys.isEmpty else { return nil }
        guard let login = user?.login else {
            uiLog.notice("The GitHub user isn't loaded yet, so this refresh counts everyone's issues, pull requests and runs")
            return nil
        }
        return MineScope(login: login, keys: keys)
    }

    public func setReviewRequests(_ mode: ReviewRequestMode) {
        prefs.reviewRequests = mode
        requestRefresh(force: true)
    }

    /// Whose review requests the next refresh counts. Needs the signed-in login.
    private var reviewScope: ReviewScope? {
        guard prefs.reviewRequests != .off else { return nil }
        guard let login = user?.login else {
            uiLog.notice("The GitHub user isn't loaded yet, so this refresh doesn't count review requests")
            return nil
        }
        return ReviewScope(login: login, needingApproval: prefs.reviewRequests == .needingApproval)
    }

    public func notifiesReleases(of id: TrackedRepo.ID) -> Bool {
        prefs.releaseNotifications.contains(id)
    }

    /// Turns release notifications on or off for repositories, asking macOS for permission the first time.
    public func setReleaseNotifications(_ ids: [TrackedRepo.ID], _ enabled: Bool) {
        if enabled {
            prefs.releaseNotifications.formUnion(ids)
            Task { await notifier.requestAuthorization() }
        } else {
            prefs.releaseNotifications.subtract(ids)
        }
    }

    /// Release notifications that are on for repositories still tracked.
    public var releaseNotificationCount: Int {
        prefs.repos.items.count { prefs.releaseNotifications.contains($0.id) }
    }

    public func setHidden(_ id: TrackedRepo.ID, _ hidden: Bool) {
        prefs.repos.setHidden(id, hidden)
        if hidden { expanded.remove(id) }
    }

    /// "Move Up" and "Move Down" for a repository key or a `RepoGroup.entryID`. Only the custom order can change.
    public func canMove(_ id: String, by offset: Int) -> Bool {
        prefs.menuSort == .custom && prefs.repos.canMove(id, by: offset, including: isListed)
    }

    public func move(_ id: String, by offset: Int) {
        guard canMove(id, by: offset) else { return }
        prefs.repos.move(id, by: offset, including: isListed)
    }

    // MARK: Groups

    /// Opens the group sheet in Settings.
    public func showGroupEditor(_ editor: GroupEditor) {
        groupEditor = editor
        actions.showSettings(.repositories)
    }

    /// Applies the group sheet: creates the group when `id` is `nil`, otherwise renames it and sets its members.
    /// Returns `nil` when the group was deleted in the meantime.
    @discardableResult
    public func saveGroup(_ id: RepoGroup.ID?, name: String, members: [TrackedRepo.ID]) -> RepoGroup.ID? {
        var repos = prefs.repos
        guard let id else {
            let created = repos.addGroup(named: name, members: members)
            prefs.repos = repos
            return created
        }
        guard repos.group(id) != nil else { return nil }
        repos.renameGroup(id, to: name)
        repos.setMembers(of: id, to: members)
        prefs.repos = repos
        return id
    }

    public func renameGroup(_ id: RepoGroup.ID, to name: String) {
        prefs.repos.renameGroup(id, to: name)
    }

    /// Deletes the group only; its repositories stay tracked, ungrouped.
    public func removeGroup(_ id: RepoGroup.ID) {
        prefs.repos.removeGroup(id)
        collapsedSettingsGroups.remove(id)
    }

    public func setGroup(_ ids: [TrackedRepo.ID], to group: RepoGroup.ID?) {
        prefs.repos.setGroup(ids, to: group)
    }

    public func toggleGroup(_ id: RepoGroup.ID) {
        guard let group = prefs.repos.group(id) else { return }
        prefs.repos.setGroupExpanded(id, !group.isExpanded)
    }

    public func toggleSettingsGroup(_ id: RepoGroup.ID) {
        if collapsedSettingsGroups.remove(id) == nil { collapsedSettingsGroups.insert(id) }
    }

    public func setSettingsGroupsCollapsed(_ collapsed: Bool) {
        collapsedSettingsGroups = collapsed ? Set(prefs.repos.groups.map(\.id)) : []
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

    // MARK: Local clones

    public func setSyncClones(_ enabled: Bool) {
        prefs.syncClones = enabled
        if enabled { workspace.syncAll(statuses: statuses) }
    }

    public func syncAllClones() {
        workspace.syncAll(statuses: statuses)
    }

    public func syncClones(of repo: TrackedRepo) {
        workspace.sync(repo.ref, statuses: statuses)
    }

    public func setCloneSyncOptedOut(_ ref: RepoRef, _ optedOut: Bool) {
        workspace.setOptedOut(ref, optedOut, statuses: statuses)
    }

    public func revealClones(of repo: TrackedRepo) {
        let paths = workspace.clones(of: repo.ref).map(\.path)
        guard !paths.isEmpty else { return }
        actions.revealInFinder(paths)
    }

    /// Shows the update status in Settings and checks right away.
    public func checkForUpdates() {
        actions.showSettings(.general)
        updater.checkNow()
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

    /// Turning alerts on asks again for every repository right away, so newly granted access shows up.
    public func setShowSecurityAlerts(_ show: Bool) {
        prefs.showSecurityAlerts = show
        if show {
            Task {
                await client.retryUnreadableAlerts()
                await refresh(force: true)
            }
        } else {
            for key in statuses.keys { statuses[key]?.securityAlerts = nil }
            if filter == .securityAlerts { filter = nil }
        }
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
        guard loginItemAvailable, !prefs.loginItemConfigured else { return }
        prefs.loginItemConfigured = true
        setLaunchAtLogin(true)
    }
}

extension StatusCache {
    /// `StatusCache.json` next to the update state in `~/Library/Application Support/Shipwatch`.
    public static var standard: StatusCache {
        StatusCache(url: ShipwatchBundle.supportDirectory.appendingPathComponent("StatusCache.json"))
    }
}
