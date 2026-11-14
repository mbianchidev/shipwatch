import Foundation
import Testing
@testable import ShipwatchCore

struct RepoRefTests {
    @Test(arguments: [
        "mbianchidev/api-server",
        "  mbianchidev/api-server\n",
        "github.com/mbianchidev/api-server",
        "https://github.com/mbianchidev/api-server",
        "https://www.github.com/mbianchidev/api-server/pulls?q=is%3Aopen",
        "https://github.com/mbianchidev/api-server.git",
        "git@github.com:mbianchidev/api-server.git",
    ])
    func parsesCommonForms(_ input: String) {
        #expect(RepoRef(parsing: input) == RepoRef(owner: "mbianchidev", name: "api-server"))
    }

    @Test(arguments: ["", "api-server", "/api-server", "-bad/api-server", "acme-org/..", "acme org/infra", "acme-org/in fra"])
    func rejectsInvalid(_ input: String) {
        #expect(RepoRef(parsing: input) == nil)
    }

    @Test func keyIsCaseInsensitive() {
        #expect(RepoRef(owner: "Acme-Org", name: "Infra").key == RepoRef(owner: "acme-org", name: "infra").key)
    }
}

struct RepoListTests {
    let api = RepoRef(owner: "mbianchidev", name: "api-server")
    let web = RepoRef(owner: "mbianchidev", name: "website")
    let cli = RepoRef(owner: "mbianchidev", name: "cli-tool")
    let infra = RepoRef(owner: "acme-org", name: "infra")

    @Test func addSkipsDuplicatesCaseInsensitively() {
        var list = RepoList()
        #expect(list.add([api, web]) == 2)
        #expect(list.add([RepoRef(owner: "MBIANCHIDEV", name: "API-SERVER"), cli]) == 1)
        #expect(list.items.map(\.ref) == [api, web, cli])
    }

    @Test func hideShowAndRemove() {
        var list = RepoList([TrackedRepo(ref: api), TrackedRepo(ref: web), TrackedRepo(ref: cli)])
        list.setHidden(web.key, true)
        #expect(list.visible.map(\.ref) == [api, cli])
        #expect(list.hiddenCount == 1)
        list.setHidden(web.key, false)
        list.remove(api.key)
        #expect(list.items.map(\.ref) == [web, cli])
    }

    @Test func moveMatchesSwiftUISemantics() {
        var list = RepoList([api, web, cli, infra].map { TrackedRepo(ref: $0) })
        list.move(fromOffsets: [0], toOffset: 3)
        #expect(list.items.map(\.ref) == [web, cli, api, infra])
        list.move(fromOffsets: [3], toOffset: 0)
        #expect(list.items.map(\.ref) == [infra, web, cli, api])
        list.move(fromOffsets: [0, 2], toOffset: 4)
        #expect(list.items.map(\.ref) == [web, api, infra, cli])
    }

    @Test func moveVisibleSkipsHiddenRepos() {
        var list = RepoList([TrackedRepo(ref: api), TrackedRepo(ref: web, hidden: true), TrackedRepo(ref: cli)])
        list.moveVisible(cli.key, by: -1)
        #expect(list.visible.map(\.ref) == [cli, api])
        list.moveVisible(cli.key, by: -1)
        #expect(list.visible.map(\.ref) == [cli, api])
        list.moveVisible(api.key, by: 1)
        #expect(list.visible.map(\.ref) == [cli, api])
    }
}

struct LinkTests {
    let ref = RepoRef(owner: "acme-org", name: "payments")

    @Test func dependabotLinkFiltersOpenDependabotPRs() throws {
        let url = GitHubLinks.dependabotPullRequests(ref)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/acme-org/payments/pulls")
        #expect(components.queryItems?.first?.value == "is:pr is:open author:app/dependabot")
    }
}

struct RelativeTimeTests {
    let now = Fixtures.now

    static let shortCases: [(TimeInterval, String)] = [
        (30, "now"), (240, "4m"), (21_600, "6h"), (259_200, "3d"), (1_296_000, "2w"),
        (7_776_000, "3mo"), (69_120_000, "2y"),
    ]

    @Test(arguments: shortCases)
    func short(_ age: TimeInterval, _ expected: String) {
        #expect(RelativeTime.short(now.addingTimeInterval(-age), now: now) == expected)
    }

    @Test func durationsAndCountdown() {
        #expect(RelativeTime.duration(192) == "3m 12s")
        #expect(RelativeTime.duration(3840) == "1h 4m")
        #expect(RelativeTime.countdown(872) == "14:32")
        #expect(RelativeTime.updated(now.addingTimeInterval(-32), now: now) == "32 s ago")
    }
}
