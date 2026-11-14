import Foundation
import Testing
@testable import ShipwatchCore

struct DeviceFlowTests {
    static let code = DeviceCode(
        deviceCode: "device-123", userCode: "WDJB-MJHT",
        verificationUri: URL(string: "https://github.com/login/device")!, expiresIn: 900, interval: 5
    )

    @Test func requestsCodeWithClientID() async throws {
        let transport = MockTransport { request in
            #expect(request.url?.path == "/login/device/code")
            #expect(request.formFields["client_id"] == "Iv1.test")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return .json(#"{"device_code":"device-123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
        }
        let flow = DeviceFlow(clientID: " Iv1.test ", transport: transport)
        #expect(try await flow.requestCode() == Self.code)
    }

    @Test func missingOrUnknownClientID() async {
        await #expect(throws: DeviceFlowError.missingClientID) {
            try await DeviceFlow(clientID: "", transport: MockTransport { _ in .json("{}") }).requestCode()
        }
        let notFound = MockTransport { _ in .json(#"{"error":"Not Found"}"#, status: 404) }
        await #expect(throws: DeviceFlowError.invalidClient) {
            try await DeviceFlow(clientID: "Iv1.nope", transport: notFound).requestCode()
        }
    }

    @Test func pollsUntilApprovedAndHonoursSlowDown() async throws {
        let clock = Clock(Fixtures.now)
        let replies = ReplyQueue([
            .json(#"{"error":"authorization_pending"}"#),
            .json(#"{"error":"slow_down","interval":10}"#),
            .json(#"{"access_token":"ghu_abc","refresh_token":"ghr_def","expires_in":28800,"refresh_token_expires_in":15897600,"token_type":"bearer"}"#),
        ])
        let sleeps = ReplyLog()
        let transport = MockTransport { request in
            #expect(request.formFields["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
            #expect(request.formFields["device_code"] == "device-123")
            return replies.next()
        }
        let flow = DeviceFlow(
            clientID: "Iv1.test", transport: transport,
            sleep: { duration in
                sleeps.append(duration.components.seconds)
                clock.advance(TimeInterval(duration.components.seconds))
            },
            now: { clock.now }
        )
        let token = try await flow.waitForToken(Self.code)
        #expect(token.accessToken == "ghu_abc")
        #expect(token.refreshToken == "ghr_def")
        #expect(token.expiresAt == Fixtures.now.addingTimeInterval(20 + 28800))
        #expect(sleeps.values == [5, 5, 10])
    }

    @Test(arguments: [
        ("access_denied", DeviceFlowError.denied),
        ("expired_token", DeviceFlowError.expired),
        ("device_flow_disabled", DeviceFlowError.deviceFlowDisabled),
    ])
    func terminalErrors(_ error: String, _ expected: DeviceFlowError) async {
        let transport = MockTransport { _ in .json(#"{"error":"\#(error)"}"#) }
        let flow = DeviceFlow(clientID: "Iv1.test", transport: transport, sleep: { _ in })
        await #expect(throws: expected) { try await flow.waitForToken(Self.code) }
    }

    @Test func stopsAtTheDeadline() async {
        let clock = Clock(Fixtures.now)
        let transport = MockTransport { _ in .json(#"{"error":"authorization_pending"}"#) }
        let flow = DeviceFlow(
            clientID: "Iv1.test", transport: transport,
            sleep: { clock.advance(TimeInterval($0.components.seconds)) }, now: { clock.now }
        )
        let short = DeviceCode(deviceCode: "d", userCode: "U", verificationUri: GitHubLinks.deviceLogin, expiresIn: 12, interval: 5)
        await #expect(throws: DeviceFlowError.expired) { try await flow.waitForToken(short) }
        #expect(transport.requests.count == 2)
    }

    @Test func refreshSendsNoSecret() async throws {
        let transport = MockTransport { request in
            #expect(request.formFields == ["client_id": "Iv1.test", "grant_type": "refresh_token", "refresh_token": "ghr_old"])
            return .json(#"{"access_token":"ghu_new","refresh_token":"ghr_new","expires_in":28800}"#)
        }
        let flow = DeviceFlow(clientID: "Iv1.test", transport: transport, now: { Fixtures.now })
        let token = try await flow.refresh("ghr_old")
        #expect(token == OAuthToken(accessToken: "ghu_new", refreshToken: "ghr_new", expiresAt: Fixtures.now.addingTimeInterval(28800)))
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(DeviceFlow.formEncode(["b": "x y", "a": "1+2&3"]) == "a=1%2B2%263&b=x%20y")
    }
}

struct TokenVaultTests {
    @Test func notSignedInWithoutTokenOrCLI() async {
        let vault = TokenVault(store: MemoryTokenStore(), cli: GitHubCLI(executable: nil))
        await #expect(throws: GitHubError.notSignedIn) { try await vault.accessToken() }
        #expect(await vault.method == nil)
    }

    @Test func freshTokenIsReturnedAsIs() async throws {
        let store = MemoryTokenStore(OAuthToken(accessToken: "ghu_live", expiresAt: Fixtures.now.addingTimeInterval(3600)))
        let vault = TokenVault(store: store, cli: GitHubCLI(executable: nil), now: { Fixtures.now })
        #expect(try await vault.restore() == .githubApp)
        #expect(try await vault.accessToken() == "ghu_live")
    }

    @Test func refreshesOnceWhenCloseToExpiry() async throws {
        let transport = MockTransport { _ in .json(#"{"access_token":"ghu_new","refresh_token":"ghr_new","expires_in":28800}"#) }
        let store = MemoryTokenStore(OAuthToken(accessToken: "ghu_old", refreshToken: "ghr_old", expiresAt: Fixtures.now.addingTimeInterval(60)))
        let vault = TokenVault(
            store: store, cli: GitHubCLI(executable: nil),
            flow: DeviceFlow(clientID: "Iv1.test", transport: transport, now: { Fixtures.now }), now: { Fixtures.now }
        )
        try await vault.restore()
        async let first = vault.accessToken()
        async let second = vault.accessToken()
        #expect(try await [first, second] == ["ghu_new", "ghu_new"])
        #expect(transport.requests.count == 1)
        #expect(try store.load()?.accessToken == "ghu_new")
    }

    @Test func rejectedRefreshSignsOut() async throws {
        let transport = MockTransport { _ in .json(#"{"error":"bad_refresh_token"}"#) }
        let store = MemoryTokenStore(OAuthToken(accessToken: "ghu_old", refreshToken: "ghr_old", expiresAt: Fixtures.now.addingTimeInterval(-10)))
        let vault = TokenVault(
            store: store, cli: GitHubCLI(executable: nil),
            flow: DeviceFlow(clientID: "Iv1.test", transport: transport), now: { Fixtures.now }
        )
        try await vault.restore()
        await #expect(throws: GitHubError.unauthorized) { try await vault.accessToken() }
        #expect(try store.load() == nil)
        #expect(await vault.method == nil)
    }

    @Test func signOutDisablesCLIFallback() async throws {
        let vault = TokenVault(store: MemoryTokenStore(), cli: GitHubCLI(executable: nil), cliEnabled: true)
        #expect(await vault.method == .githubCLI)
        try await vault.signOut()
        #expect(await vault.method == nil)
    }
}

final class ReplyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int64] = []

    func append(_ value: Int64) { lock.withLock { stored.append(value) } }
    var values: [Int64] { lock.withLock { stored } }
}
