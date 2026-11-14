import Foundation
import os

public enum AuthMethod: String, Sendable, Equatable {
    case githubApp
    case githubCLI
}

let log = Logger(subsystem: "dev.mbianchi.shipwatch", category: "core")

/// Hands out a valid access token: the GitHub App token (refreshed when close to expiry),
/// or the GitHub CLI token when the fallback is on and no app token exists.
public actor TokenVault {
    private let store: any TokenStore
    private let cli: GitHubCLI
    private let now: @Sendable () -> Date
    private var flow: DeviceFlow?
    private var appToken: OAuthToken?
    private var cliEnabled: Bool
    private var cliCache: (token: String, fetchedAt: Date)?
    private var refreshing: Task<OAuthToken, Error>?
    private let cliCacheLifetime: TimeInterval = 300

    public init(
        store: any TokenStore,
        cli: GitHubCLI = GitHubCLI(),
        flow: DeviceFlow? = nil,
        cliEnabled: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.cli = cli
        self.flow = flow
        self.cliEnabled = cliEnabled
        self.now = now
    }

    /// Loads a previously saved app token. Returns the active method, if any.
    @discardableResult
    public func restore() throws -> AuthMethod? {
        appToken = try store.load()
        return method
    }

    public var method: AuthMethod? {
        if appToken != nil { return .githubApp }
        return cliEnabled ? .githubCLI : nil
    }

    public func setDeviceFlow(_ flow: DeviceFlow?) {
        self.flow = flow
    }

    public func setCLIEnabled(_ enabled: Bool) {
        cliEnabled = enabled
        if !enabled { cliCache = nil }
    }

    public func signIn(with token: OAuthToken) throws {
        appToken = token
        try store.save(token)
    }

    public func signOut() throws {
        appToken = nil
        cliCache = nil
        cliEnabled = false
        refreshing?.cancel()
        refreshing = nil
        try store.delete()
    }

    /// Called after a 401: the next request refreshes the app token or re-reads the CLI token.
    public func discardCurrentToken() {
        if appToken != nil {
            appToken?.expiresAt = .distantPast
        }
        cliCache = nil
    }

    public func accessToken() async throws -> String {
        if let token = appToken {
            guard token.needsRefresh(now: now()) else { return token.accessToken }
            return try await refreshedToken(from: token).accessToken
        }
        if cliEnabled {
            if let cliCache, now().timeIntervalSince(cliCache.fetchedAt) < cliCacheLifetime {
                return cliCache.token
            }
            let token = try await cli.token()
            cliCache = (token, now())
            return token
        }
        throw GitHubError.notSignedIn
    }

    private func refreshedToken(from current: OAuthToken) async throws -> OAuthToken {
        if let refreshing { return try await refreshing.value }
        let stillValid = (current.expiresAt ?? .distantFuture) > now()
        guard let flow, let refreshToken = current.refreshToken, current.canRefresh(now: now()) else {
            if stillValid { return current }
            expire()
            throw GitHubError.unauthorized
        }

        let task = Task { try await flow.refresh(refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let token = try await task.value
            appToken = token
            do {
                try store.save(token)
            } catch {
                log.error("Refreshed token could not be saved: \(error.localizedDescription, privacy: .public)")
            }
            return token
        } catch DeviceFlowError.invalidRefreshToken {
            expire()
            throw GitHubError.unauthorized
        } catch {
            log.error("Token refresh failed: \(error.localizedDescription, privacy: .public)")
            if stillValid { return current }
            throw error
        }
    }

    private func expire() {
        appToken = nil
        do {
            try store.delete()
        } catch {
            log.error("Expired token could not be removed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
