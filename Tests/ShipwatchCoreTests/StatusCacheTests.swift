import Foundation
import Testing
@testable import ShipwatchCore

struct StatusCacheTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shipwatch-tests-\(UUID().uuidString)")
    var cache: StatusCache { StatusCache(url: directory.appendingPathComponent("Shipwatch/StatusCache.json")) }

    @Test func roundTripsEveryStatusDetail() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = RepoRef(owner: "octocat", name: "api-server")
        var blocked = Fixtures.run(2, workflow: 20, conclusion: "failure", created: "2026-11-14T15:00:00Z")
        blocked.jobsNeverStarted = true
        let running = Fixtures.run(3, workflow: 10, status: "in_progress", conclusion: nil, created: "2026-11-14T15:30:00Z")
        let queued = Fixtures.run(4, workflow: 30, status: "queued", conclusion: nil, created: "2026-11-14T15:35:00Z")
        let status = RepoStatus(
            ref: api, isPrivate: true, defaultBranch: "main", defaultBranchHead: "9f1c2e7",
            latestRelease: Release(
                tagName: "v1.2.0", url: URL(string: "https://github.com/octocat/api-server/releases/tag/v1.2.0")!,
                publishedAt: Fixtures.date("2026-11-11T10:00:00Z"), isPrerelease: true
            ),
            openIssues: 4, openPullRequests: 2, dependabotPullRequests: 1, pushedAt: Fixtures.now,
            ci: CISummary(state: .running, running: [running], queued: [queued], latestOnDefault: [blocked]),
            securityAlerts: SecurityAlerts(dependabot: 3, codeScanning: nil, secretScanning: 0)
        )
        let gone = RepoStatus(ref: RepoRef(owner: "acme-org", name: "legacy-api"), problem: .error("Server error"))
        let snapshot = StatusSnapshot(savedAt: Fixtures.now, statuses: [api.key: status, gone.ref.key: gone])

        try cache.save(snapshot)

        let loaded = try #require(try cache.load())
        #expect(loaded == snapshot)
        #expect(loaded.statuses[api.key]?.ci?.latestOnDefault.first?.didNotStart == true)
        let permissions = try FileManager.default.attributesOfItem(atPath: cache.url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func missingOrOtherVersionLoadsNothing() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try cache.load() == nil)
        try cache.remove()

        var snapshot = StatusSnapshot(savedAt: Fixtures.now, statuses: [:])
        snapshot.version = StatusSnapshot.currentVersion + 1
        try cache.save(snapshot)
        #expect(try cache.load() == nil)

        try cache.remove()
        #expect(!FileManager.default.fileExists(atPath: cache.url.path))
    }

    @Test func unreadableSnapshotThrows() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: cache.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":\#(StatusSnapshot.currentVersion),"savedAt":0}"#.utf8).write(to: cache.url)
        #expect(throws: DecodingError.self) { try cache.load() }
    }
}
