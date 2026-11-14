import Foundation
import Testing
@testable import ShipwatchUpdate

struct UpdateFeedTests {
    private static let current = UpdateVersion(major: 1, minor: 2, patch: 3)

    private func asset(_ name: String, tag: String = "v1.2.4", size: Int = 1000) -> [String: Any] {
        ["name": name, "size": size, "browser_download_url": "https://github.com/mbianchidev/shipwatch/releases/download/\(tag)/\(name)"]
    }

    private func feed(
        tag: String = "v1.2.4",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [[String: Any]]? = nil
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "html_url": "https://github.com/mbianchidev/shipwatch/releases/tag/\(tag)",
            "body": "<b>Fixes</b>\n",
            "draft": draft,
            "prerelease": prerelease,
            "assets": assets ?? [asset("Shipwatch.dmg.sha256"), asset("Shipwatch.dmg"), asset("Shipwatch.dmg.sig", size: 300)],
        ])
    }

    @Test func newerReleaseIsAvailableWithTrustedAssets() throws {
        let result = try UpdateFeed.evaluate(feed(), current: Self.current)
        guard case .available(let release) = result else {
            Issue.record("Expected an available release, got \(result)")
            return
        }
        #expect(release.version == UpdateVersion(major: 1, minor: 2, patch: 4))
        #expect(release.notes == "<b>Fixes</b>")
        #expect(release.pageURL.absoluteString == "https://github.com/mbianchidev/shipwatch/releases/tag/v1.2.4")
        #expect(release.diskImage.url.absoluteString == "https://github.com/mbianchidev/shipwatch/releases/download/v1.2.4/Shipwatch.dmg")
        #expect(release.signature.size == 300)
    }

    @Test func equalLowerDraftAndPrereleaseAreNotOffered() throws {
        #expect(try UpdateFeed.evaluate(feed(tag: "v1.2.3", assets: []), current: Self.current) == .upToDate)
        #expect(try UpdateFeed.evaluate(feed(tag: "v1.1.9", assets: []), current: Self.current) == .upToDate)
        #expect(try UpdateFeed.evaluate(feed(draft: true), current: Self.current) == .upToDate)
        #expect(try UpdateFeed.evaluate(feed(prerelease: true), current: Self.current) == .upToDate)
    }

    @Test(arguments: [
        "https://github.com/someone/shipwatch/releases/download/v1.2.4/Shipwatch.dmg",
        "https://evil.example/mbianchidev/shipwatch/releases/download/v1.2.4/Shipwatch.dmg",
        "http://github.com/mbianchidev/shipwatch/releases/download/v1.2.4/Shipwatch.dmg",
        "https://github.com/mbianchidev/shipwatch/releases/download/v1.2.3/Shipwatch.dmg",
    ])
    func untrustedAssetURLIsRejected(url: String) throws {
        var image = asset("Shipwatch.dmg")
        image["browser_download_url"] = url
        let data = try feed(assets: [image, asset("Shipwatch.dmg.sig")])
        #expect(throws: UpdateFeedError.untrustedAssetURL("Shipwatch.dmg")) {
            try UpdateFeed.evaluate(data, current: Self.current)
        }
    }

    @Test func missingOrBadAssetsAreErrorsNotUpToDate() throws {
        #expect(throws: UpdateFeedError.missingAsset("Shipwatch.dmg.sig")) {
            try UpdateFeed.evaluate(feed(assets: [asset("Shipwatch.dmg")]), current: Self.current)
        }
        for size in [0, 64 << 20 + 1] {
            #expect(throws: UpdateFeedError.invalidAssetSize("Shipwatch.dmg")) {
                try UpdateFeed.evaluate(feed(assets: [asset("Shipwatch.dmg", size: size), asset("Shipwatch.dmg.sig")]), current: Self.current)
            }
        }
        #expect(throws: UpdateFeedError.invalidAssetSize("Shipwatch.dmg.sig")) {
            try UpdateFeed.evaluate(feed(assets: [asset("Shipwatch.dmg"), asset("Shipwatch.dmg.sig", size: 4097)]), current: Self.current)
        }
        #expect(throws: UpdateFeedError.invalidTag("1.2.4")) {
            try UpdateFeed.evaluate(feed(tag: "1.2.4"), current: Self.current)
        }
        #expect(throws: UpdateFeedError.invalidResponse) {
            try UpdateFeed.evaluate(Data(#"{"message":"API rate limit exceeded"}"#.utf8), current: Self.current)
        }
    }

    @Test func releasePageRedirectOffersNewerTagWithFixedAssets() throws {
        let location = try #require(URL(string: "https://github.com/mbianchidev/shipwatch/releases/tag/v1.2.4"))
        let result = try UpdateFeed.evaluate(latestReleaseLocation: location, current: Self.current)
        guard case .available(let release) = result else {
            Issue.record("Expected an available release, got \(result)")
            return
        }
        #expect(release.version == UpdateVersion(major: 1, minor: 2, patch: 4))
        #expect(release.pageURL == location)
        #expect(release.diskImage.url.absoluteString == "https://github.com/mbianchidev/shipwatch/releases/download/v1.2.4/Shipwatch.dmg")
        #expect(release.diskImage.size == nil && release.diskImage.maxSize == 64 << 20)
        #expect(release.signature.url.absoluteString == "https://github.com/mbianchidev/shipwatch/releases/download/v1.2.4/Shipwatch.dmg.sig")
        #expect(release.signature.maxSize == 4096)
    }

    @Test func releasePageRedirectWithoutNewerReleaseIsUpToDate() throws {
        for location in [
            "https://github.com/mbianchidev/shipwatch/releases/tag/v1.2.3",
            "https://github.com/mbianchidev/shipwatch/releases/tag/v1.1.9",
            "https://github.com/mbianchidev/shipwatch/releases",
        ] {
            #expect(try UpdateFeed.evaluate(latestReleaseLocation: #require(URL(string: location)), current: Self.current) == .upToDate)
        }
    }

    @Test(arguments: [
        "https://github.com/someone/shipwatch/releases/tag/v1.2.4",
        "https://github.com/mbianchidev/shipwatch/releases/tag/v1.2.4?x=1",
        "https://github.com/login?return_to=%2Fmbianchidev%2Fshipwatch",
        "http://github.com/mbianchidev/shipwatch/releases/tag/v1.2.4",
    ])
    func unexpectedReleasePageRedirectIsRejected(location: String) throws {
        #expect(throws: UpdateFeedError.invalidResponse) {
            try UpdateFeed.evaluate(latestReleaseLocation: #require(URL(string: location)), current: Self.current)
        }
    }

    @Test func releasePageRedirectNeedsAVersionTag() throws {
        let location = try #require(URL(string: "https://github.com/mbianchidev/shipwatch/releases/tag/v1.2.4/../evil"))
        #expect(throws: UpdateFeedError.invalidTag("v1.2.4/../evil")) {
            try UpdateFeed.evaluate(latestReleaseLocation: location, current: Self.current)
        }
    }
}

struct UpdateRateLimitTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func response(_ status: Int, _ headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: UpdateFeed.latestReleaseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }

    @Test func detectsUsedUpLimitWithItsResetTime() throws {
        let limited = try response(403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1003600"])
        #expect(UpdateDownloader.rateLimitError(limited, now: now) == .rateLimited(until: Date(timeIntervalSince1970: 1_003_600)))
        #expect(UpdateDownloader.rateLimitError(try response(429, ["Retry-After": "60"]), now: now) == .rateLimited(until: now + 60))
        #expect(UpdateDownloader.rateLimitError(try response(429), now: now) == .rateLimited(until: nil))
    }

    @Test func otherResponsesAreNotRateLimits() throws {
        #expect(UpdateDownloader.rateLimitError(try response(403), now: now) == nil)
        #expect(UpdateDownloader.rateLimitError(try response(403, ["X-RateLimit-Remaining": "12"]), now: now) == nil)
        #expect(UpdateDownloader.rateLimitError(try response(200, ["X-RateLimit-Remaining": "0"]), now: now) == nil)
    }
}

struct UpdateVersionTests {
    @Test func comparesNumericallyAndTreatsDevAsOldest() {
        #expect(UpdateVersion("1.10.0")! > UpdateVersion("1.9.12")!)
        #expect(UpdateVersion("2.0.0")! > UpdateVersion("1.99.99")!)
        #expect(UpdateVersion(bundleVersion: "dev") == .zero)
        #expect(UpdateVersion(bundleVersion: nil) < UpdateVersion("0.0.1")!)
        #expect(UpdateVersion(tag: "v0.0.1") == UpdateVersion("0.0.1"))
    }

    @Test(arguments: ["1.2", "1.2.3.4", "01.2.3", "1.2.3-beta", "v1.2.3", "1..3", "-1.2.3", "1.2.3 ", "1.2.٣"])
    func rejectsAmbiguousVersions(text: String) {
        #expect(UpdateVersion(text) == nil)
    }
}

struct UpdateRedirectTests {
    @Test func allowsOnlyHTTPSToListedHosts() {
        let hosts = UpdateDownloader.assetHosts
        #expect(UpdateDownloader.allowsRedirect(to: URL(string: "https://release-assets.githubusercontent.com/x?sig=1"), hosts: hosts))
        #expect(UpdateDownloader.allowsRedirect(to: URL(string: "https://GitHub.com/a"), hosts: hosts))
        for url in [
            "http://objects.githubusercontent.com/x",
            "https://objects.githubusercontent.com.evil.example/x",
            "https://example.com/x",
            "https://user:pass@github.com/x",
            "https://github.com:8443/x",
            "file:///etc/passwd",
        ] {
            #expect(!UpdateDownloader.allowsRedirect(to: URL(string: url), hosts: hosts), "\(url)")
        }
        #expect(!UpdateDownloader.allowsRedirect(to: nil, hosts: hosts))
        #expect(!UpdateDownloader.allowsRedirect(to: URL(string: "https://github.com/x"), hosts: UpdateDownloader.feedHosts))
    }
}
