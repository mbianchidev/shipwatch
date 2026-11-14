import Foundation

public struct DeviceCode: Equatable, Sendable, Decodable {
    public var deviceCode: String
    public var userCode: String
    public var verificationUri: URL
    public var expiresIn: Int
    public var interval: Int

    public init(deviceCode: String, userCode: String, verificationUri: URL, expiresIn: Int, interval: Int) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

/// A GitHub App user access token. Expiring tokens come with a refresh token.
public struct OAuthToken: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var refreshTokenExpiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, refreshTokenExpiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    /// Refresh a few minutes early so a request never goes out with a token about to expire.
    public func needsRefresh(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 300
    }

    public func canRefresh(now: Date = Date()) -> Bool {
        guard refreshToken != nil else { return false }
        return refreshTokenExpiresAt.map { $0 > now } ?? true
    }
}

public enum DeviceFlowError: Error, Equatable, LocalizedError {
    case missingClientID
    case expired
    case denied
    case deviceFlowDisabled
    case invalidClient
    case invalidRefreshToken
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .missingClientID:
            "No GitHub App Client ID configured. Add it in Settings, Account."
        case .expired:
            "The code expired before it was approved. Try again."
        case .denied:
            "Authorization was cancelled on GitHub."
        case .deviceFlowDisabled:
            "Device flow is disabled for this GitHub App. Enable it in the app's settings on GitHub."
        case .invalidClient:
            "GitHub doesn't recognise this Client ID. Check it in Settings, Account."
        case .invalidRefreshToken:
            "The saved session expired. Sign in again."
        case .server(let message):
            message
        }
    }
}

/// OAuth device flow for a GitHub App. No client secret: the user approves a short code on github.com.
public struct DeviceFlow: Sendable {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    public let clientID: String
    private let transport: any HTTPTransport
    private let base: URL
    private let sleep: Sleeper
    private let now: @Sendable () -> Date

    public init(
        clientID: String,
        transport: any HTTPTransport = URLSessionTransport(),
        base: URL = URL(string: "https://github.com")!,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
        self.base = base
        self.sleep = sleep
        self.now = now
    }

    public func requestCode() async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw DeviceFlowError.missingClientID }
        let (data, response) = try await post("login/device/code", ["client_id": clientID])
        if let code = try? JSON.snakeDecoder.decode(DeviceCode.self, from: data) {
            return code
        }
        let failure = try? JSON.snakeDecoder.decode(TokenResponse.self, from: data)
        if response.statusCode == 404 || response.statusCode == 401 || failure?.error == "incorrect_client_credentials" {
            throw DeviceFlowError.invalidClient
        }
        throw Self.error(for: failure) ?? DeviceFlowError.server("GitHub returned HTTP \(response.statusCode) for the device code.")
    }

    /// Polls at the interval GitHub asks for until the user approves, denies, or the code expires.
    /// Cancelling the task stops polling.
    public func waitForToken(_ code: DeviceCode) async throws -> OAuthToken {
        var interval = max(code.interval, 1)
        let deadline = now().addingTimeInterval(TimeInterval(code.expiresIn))
        while true {
            try await sleep(.seconds(interval))
            try Task.checkCancellation()
            guard now() < deadline else { throw DeviceFlowError.expired }

            let (data, _) = try await post("login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            let response = try JSON.decode(TokenResponse.self, from: data)
            if let token = response.token(now: now()) { return token }
            switch response.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = response.interval ?? interval + 5
            default:
                throw Self.error(for: response) ?? DeviceFlowError.server("GitHub returned no token.")
            }
        }
    }

    /// GitHub App refresh tokens work without the client secret.
    public func refresh(_ refreshToken: String) async throws -> OAuthToken {
        let (data, _) = try await post("login/oauth/access_token", [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        let response = try JSON.decode(TokenResponse.self, from: data)
        if let token = response.token(now: now()) { return token }
        if response.error == "bad_refresh_token" { throw DeviceFlowError.invalidRefreshToken }
        throw Self.error(for: response) ?? DeviceFlowError.server("GitHub returned no token.")
    }

    private func post(_ path: String, _ form: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)
        return try await transport.send(request)
    }

    static func formEncode(_ form: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return form.sorted { $0.key < $1.key }.map { key, value in
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encodedValue)"
        }.joined(separator: "&")
    }

    private static func error(for response: TokenResponse?) -> DeviceFlowError? {
        guard let response, let error = response.error else { return nil }
        switch error {
        case "expired_token": return .expired
        case "access_denied": return .denied
        case "device_flow_disabled": return .deviceFlowDisabled
        case "incorrect_client_credentials", "unauthorized_client": return .invalidClient
        case "bad_refresh_token": return .invalidRefreshToken
        default: return .server(response.errorDescription ?? error)
        }
    }

    struct TokenResponse: Decodable {
        var accessToken: String?
        var refreshToken: String?
        var expiresIn: Int?
        var refreshTokenExpiresIn: Int?
        var error: String?
        var errorDescription: String?
        var interval: Int?

        func token(now: Date) -> OAuthToken? {
            guard let accessToken, !accessToken.isEmpty else { return nil }
            return OAuthToken(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
                refreshTokenExpiresAt: refreshTokenExpiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
            )
        }
    }
}
