import AppKit
import Observation
import ShipwatchUpdate
import os

let updateLog = Logger(subsystem: "dev.mbianchi.shipwatch", category: "update")

/// Checks GitHub Releases for a newer Shipwatch, then downloads, verifies and installs it through the update helper.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(UpdateRelease)
        /// Fraction from 0 to 1, or nil before the first bytes arrive.
        case downloading(Double?)
        case verifying
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The newest release from the last successful check. Kept while installing and after a failed attempt.
    private(set) var availableRelease: UpdateRelease?
    private(set) var pause = UpdatePause()

    /// Only a packaged Shipwatch.app with a release version can replace itself.
    let isSupported: Bool
    let currentVersion: UpdateVersion

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let bundleVersion: String
    @ObservationIgnored private let downloader: UpdateDownloader
    @ObservationIgnored private var startupPending: Bool
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var failures = 0
    /// Keeps the helper's termination handler alive until Shipwatch quits.
    @ObservationIgnored private var helper: Process?

    init(prefs: Preferences, bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.prefs = prefs
        bundleURL = bundle.bundleURL
        bundleVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        currentVersion = UpdateVersion(bundleVersion: bundleVersion)
        isSupported = bundleURL.pathExtension == "app"
            && bundle.bundleIdentifier == ShipwatchBundle.identifier
            && currentVersion > .zero
        downloader = UpdateDownloader(appVersion: currentVersion.description)
        // After an update relaunch the old result describes the previous attempt; the helper writes the new one.
        startupPending = AppBundleStartupRequest.isRequested(in: environment)
        if isSupported && !startupPending {
            pause = UpdatePause(
                resultURL: AppBundleUpdateResult.defaultURL,
                failedVersionArgument: UserDefaults.standard.string(forKey: ShipwatchBundle.failedUpdateArgument),
                currentVersion: currentVersion
            )
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing: true
        case .idle, .upToDate, .available, .failed: false
        }
    }

    var hasFailed: Bool {
        if case .failed = state { true } else { false }
    }

    var isInstalling: Bool {
        switch state {
        case .downloading, .verifying, .installing: true
        case .idle, .checking, .upToDate, .available, .failed: false
        }
    }

    // MARK: Lifecycle

    func start() {
        scheduleNextCheck()
    }

    /// Answers the update helper that relaunched this copy, so it keeps the new version instead of rolling back.
    func confirmUpdateStartup(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard startupPending else { return }
        startupPending = false
        defer { AppBundleStartupRequest.removeFromProcessEnvironment() }
        do {
            guard let request = try AppBundleStartupRequest.read(from: environment) else { return }
            try request.acknowledge(bundleURL: bundleURL, version: bundleVersion)
            pause = UpdatePause()
            updateLog.notice("Confirmed startup after updating to \(self.bundleVersion, privacy: .public)")
        } catch {
            updateLog.error("Could not confirm the update startup: \(error.localizedDescription, privacy: .public)")
            pause = UpdatePause(pausingAll: "Shipwatch could not confirm the update: \(error.localizedDescription) Automatic installs are paused.")
        }
    }

    // MARK: Actions

    func checkNow() {
        check(automatic: false)
    }

    /// Installs the available release now. A failed version is paused only for automatic installs.
    func install() {
        guard let release = availableRelease else { return }
        run { await self.performInstall(release) }
    }

    func setCheckForUpdates(_ enabled: Bool) {
        prefs.checkForUpdates = enabled
        scheduleNextCheck()
    }

    func setUpdateCheckHours(_ hours: Int) {
        prefs.updateCheckHours = hours
        scheduleNextCheck()
    }

    private func check(automatic: Bool) {
        run { await self.performCheck(automatic: automatic) }
    }

    /// Runs one check or install at a time, then plans the next automatic check.
    private func run(_ work: @escaping @MainActor () async -> Void) {
        guard isSupported, operation == nil else { return }
        operation = Task {
            await work()
            operation = nil
            scheduleNextCheck()
        }
    }

    // MARK: Scheduling

    /// First check shortly after launch, then every interval with jitter. Failures back off from 5 minutes up to the interval.
    private func scheduleNextCheck() {
        timer?.cancel()
        timer = nil
        guard isSupported, prefs.checkForUpdates else { return }
        let interval = TimeInterval(prefs.updateCheckHours * 3600)
        let delay: TimeInterval
        if failures > 0 {
            delay = min(interval, 300 * pow(2, Double(min(failures, 10) - 1)))
        } else if let lastCheck {
            let jitter = TimeInterval.random(in: 0...min(300, interval / 10))
            delay = max(30, lastCheck.addingTimeInterval(interval).timeIntervalSinceNow) + jitter
        } else {
            delay = 30
        }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.check(automatic: true)
        }
    }

    // MARK: Work

    private func performCheck(automatic: Bool) async {
        state = .checking
        do {
            let data = try await downloader.fetchFeed()
            let result = try UpdateFeed.evaluate(data, current: currentVersion)
            let now = Date()
            lastCheck = now
            failures = 0
            switch result {
            case .upToDate:
                availableRelease = nil
                state = .upToDate(checkedAt: now)
            case .available(let release):
                availableRelease = release
                state = .available(release)
                updateLog.notice("Shipwatch \(release.version.description, privacy: .public) is available")
                if automatic, prefs.installUpdatesAutomatically, pause.allowsAutomaticInstall(of: release.version) {
                    await performInstall(release)
                }
            }
        } catch {
            lastCheck = Date()
            failures += 1
            updateLog.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("Couldn't check for updates. \(error.localizedDescription)")
        }
    }

    private func performInstall(_ release: UpdateRelease) async {
        let version = release.version.description
        updateLog.notice("Installing Shipwatch \(version, privacy: .public)")
        state = .downloading(nil)
        let workspace: UpdateWorkspace
        do {
            workspace = try UpdateWorkspace.create()
        } catch {
            installFailed(version, message: error.localizedDescription)
            return
        }
        do {
            let signature = try await downloader.fetch(release.signature)
            let image = workspace.diskImage
            try await downloader.download(release.diskImage, to: image) { fraction in
                Task { @MainActor in self.downloadProgressed(fraction) }
            }

            state = .verifying
            try await Task.detached(priority: .userInitiated) {
                try UpdateSignature.verifyRelease(fileAt: image, signatureData: signature, version: version)
            }.value

            state = .installing
            let mountPoint = workspace.mountPoint
            let appURL = bundleURL
            helper = try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.start(
                    diskImage: image,
                    mountPoint: mountPoint,
                    version: version,
                    appURL: appURL,
                    log: { updateLog.error("\($0, privacy: .public)") },
                    onHelperFailure: { message in
                        Task { @MainActor in self.installFailed(version, message: message) }
                    }
                )
            }.value
            removeWorkspace(workspace)
            updateLog.notice("Update helper is ready, quitting to install \(version, privacy: .public)")
            NSApp.terminate(nil)
        } catch {
            removeWorkspace(workspace)
            installFailed(version, message: error.localizedDescription)
        }
    }

    private func downloadProgressed(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(fraction)
    }

    private func installFailed(_ version: String, message: String) {
        updateLog.error("Installing \(version, privacy: .public) failed: \(message, privacy: .public)")
        state = .failed("Couldn't install \(version). \(message)")
        pause.pause(version, message: "Updating to \(version) failed, so it won't install automatically. Use Install to try again.")
    }

    private func removeWorkspace(_ workspace: UpdateWorkspace) {
        do {
            try workspace.remove()
        } catch {
            updateLog.error("Could not remove \(workspace.directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
