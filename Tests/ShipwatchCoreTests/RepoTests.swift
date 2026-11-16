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

    @Test func decodesListsSavedBeforeGroups() throws {
        let json = #"{"items":[{"ref":{"owner":"mbianchidev","name":"api-server"},"hidden":true}]}"#
        let list = try JSONDecoder().decode(RepoList.self, from: Data(json.utf8))
        #expect(list.items == [TrackedRepo(ref: api, hidden: true)])
        #expect(list.groups.isEmpty)
    }

    @Test func renameKeepsPlaceAndRemembersTheFormerName() {
        var list = RepoList([TrackedRepo(ref: api, hidden: true), TrackedRepo(ref: web)])
        let moved = RepoRef(owner: "acme-org", name: "api")
        let renamed = list.rename(api.key, to: moved)
        #expect(renamed)
        #expect(list.items.map(\.ref) == [moved, web])
        #expect(list.items[0].hidden)
        #expect(list.aliases == [api.key: moved])
        let again = list.rename(moved.key, to: moved)
        #expect(!again)
    }

    @Test func renameOntoATrackedRepoMergesThem() {
        var list = RepoList([TrackedRepo(ref: api), TrackedRepo(ref: web, hidden: true)])
        let merged = list.rename(api.key, to: RepoRef(owner: "MBianchiDev", name: "Website"))
        #expect(merged)
        #expect(list.items.map(\.ref) == [web])
        #expect(list.items[0].hidden)
        #expect(list.aliases == [api.key: web])
    }

    @Test func groupMembersStayTogetherWhereTheFirstOneIs() throws {
        var list = RepoList([api, web, cli, infra].map { TrackedRepo(ref: $0) })
        let tools = list.addGroup(named: "Tools", members: [cli.key, api.key])
        let group = try #require(list.group(tools))
        #expect(list.items.map(\.ref) == [api, cli, web, infra])
        #expect(list.entries() == [.group(group, members: list.members(of: tools)), .repo(list.items[2]), .repo(list.items[3])])
        #expect(list.rows.map(\.id) == [group.entryID, api.key, cli.key, web.key, infra.key])

        list.setGroup([infra.key], to: tools)
        #expect(list.items.map(\.ref) == [api, cli, infra, web])
        list.setGroup([api.key], to: nil)
        #expect(list.items.map(\.ref) == [api, cli, infra, web])
        #expect(list.members(of: tools).map(\.ref) == [cli, infra])

        list.removeGroup(tools)
        #expect(list.groups.isEmpty)
        #expect(list.entries().map(\.id) == [api.key, cli.key, infra.key, web.key])
    }

    @Test func emptyGroupsOnlyShowInSettings() {
        var list = RepoList([TrackedRepo(ref: api)])
        let empty = list.addGroup(named: list.unusedGroupName())
        #expect(list.group(empty)?.name == "New Group")
        #expect(list.unusedGroupName() == "New Group 2")
        #expect(list.entries().map(\.id) == [api.key])
        #expect(list.rows.map(\.id) == [api.key, RepoGroup.entryID(empty)])
    }

    /// Rows: [Tools] api cli | web infra
    func toolsList() -> (RepoList, RepoGroup.ID) {
        var list = RepoList([api, cli, web, infra].map { TrackedRepo(ref: $0) })
        let tools = list.addGroup(named: "Tools", members: [api.key, cli.key])
        return (list, tools)
    }

    @Test func draggingARepoIntoAGroupJoinsIt() {
        var (list, tools) = toolsList()
        list.moveRows(fromOffsets: [3], toOffset: 2)
        #expect(list.items.map(\.ref) == [api, web, cli, infra])
        #expect(list.members(of: tools).map(\.ref) == [api, web, cli])
    }

    @Test func droppingAfterTheLastMemberKeepsOnlyMembersInside() {
        var (list, tools) = toolsList()
        list.moveRows(fromOffsets: [1], toOffset: 3)
        #expect(list.members(of: tools).map(\.ref) == [cli, api])
        list.moveRows(fromOffsets: [4], toOffset: 3)
        #expect(list.members(of: tools).map(\.ref) == [cli, api])
        #expect(list.items.map(\.ref) == [cli, api, infra, web])
        list.moveRows(fromOffsets: [1], toOffset: 0)
        #expect(list.members(of: tools).map(\.ref) == [api])
        #expect(list.rows.map(\.id).first == cli.key)
    }

    @Test func draggingAGroupMovesItsMembersBetweenEntries() {
        var (list, tools) = toolsList()
        list.moveRows(fromOffsets: [0], toOffset: 5)
        #expect(list.items.map(\.ref) == [web, infra, api, cli])
        list.moveRows(fromOffsets: [2], toOffset: 1)
        #expect(list.items.map(\.ref) == [web, api, cli, infra])
        #expect(list.members(of: tools).map(\.ref) == [api, cli])
    }

    @Test func collapsedGroupsHideTheirMembersAndDragsLandAroundThem() {
        var (list, tools) = toolsList()
        let collapsed: Set = [tools]
        #expect(list.rows(collapsing: collapsed).map(\.id) == [RepoGroup.entryID(tools), web.key, infra.key])
        list.moveRows(fromOffsets: [2], toOffset: 1, collapsing: collapsed)
        #expect(list.items.map(\.ref) == [api, cli, infra, web])
        #expect(list.members(of: tools).map(\.ref) == [api, cli])
        list.moveRows(fromOffsets: [0], toOffset: 3, collapsing: collapsed)
        #expect(list.items.map(\.ref) == [infra, web, api, cli])
        #expect(list.members(of: tools).map(\.ref) == [api, cli])

        let empty = list.addGroup(named: "Empty")
        list.moveRows(fromOffsets: [0], toOffset: 4, collapsing: [tools, empty])
        #expect(list.members(of: empty).isEmpty)
        #expect(list.rows(collapsing: [tools, empty]).map(\.id).contains(infra.key))
    }

    @Test func setMembersMakesTheGroupExactlyThoseRepositories() {
        var (list, tools) = toolsList()
        list.setMembers(of: tools, to: [cli.key, infra.key])
        #expect(list.members(of: tools).map(\.ref) == [cli, infra])
        #expect(list.items.map(\.ref) == [api, cli, infra, web])
        list.setMembers(of: tools, to: [])
        #expect(list.members(of: tools).isEmpty)
        #expect(list.group(tools) != nil)
    }

    @Test func moveSkipsHiddenReposAndPassesWholeGroups() {
        var (list, tools) = toolsList()
        list.setHidden(web.key, true)
        let shown: (TrackedRepo) -> Bool = { !$0.hidden }
        #expect(list.siblings(of: cli.key, including: shown) == [api.key, cli.key])
        #expect(!list.canMove(cli.key, by: 1, including: shown))
        list.move(infra.key, by: -1, including: shown)
        #expect(list.items.map(\.ref) == [infra, api, cli, web])
        list.move(RepoGroup.entryID(tools), by: -1, including: shown)
        #expect(list.items.map(\.ref) == [api, cli, infra, web])
        list.move(cli.key, by: -1, including: shown)
        #expect(list.items.map(\.ref) == [cli, api, infra, web])
    }

    @Test func searchShowsMatchesUnderTheirGroupEvenWhenCollapsed() {
        let (list, tools) = toolsList()
        let header = RepoGroup.entryID(tools)
        #expect(list.rows(collapsing: [tools], matching: SearchText("  CLI ")).map(\.id) == [header, cli.key])
        #expect(list.rows(collapsing: [], matching: SearchText("acme-org/")).map(\.id) == [infra.key])
        #expect(list.rows(collapsing: [tools], matching: SearchText("tools")).map(\.id) == [header, api.key, cli.key])
        #expect(list.rows(collapsing: [], matching: SearchText("nothing")).isEmpty)
        #expect(list.rows(collapsing: [tools], matching: SearchText(" ")) == list.rows(collapsing: [tools]))
    }

    @Test func ownersAreCountedCaseInsensitively() {
        var list = RepoList([api, infra, web].map { TrackedRepo(ref: $0) })
        list.add([RepoRef(owner: "Acme-Org", name: "payments")])
        #expect(list.owners() == [RepoOwner(login: "acme-org", count: 2), RepoOwner(login: "mbianchidev", count: 2)])
        #expect(list.owners { $0.ref != web }.map(\.count) == [2, 1])
    }

    @Test func sortsEntriesAndGroupMembers() throws {
        var list = RepoList([web, api, infra, cli].map { TrackedRepo(ref: $0) })
        let zeta = list.addGroup(named: "zeta", members: [infra.key, cli.key])
        let entries = list.entries()
        let byName = entries.sorted(by: .name) { _ in nil }
        #expect(byName.map(\.id) == [api.key, web.key, RepoGroup.entryID(zeta)])
        #expect(byName.last?.repos.map(\.ref) == [cli, infra])

        let now = Fixtures.now
        let activity: [String: Date] = [web.key: now.addingTimeInterval(-60), cli.key: now, infra.key: now.addingTimeInterval(-600)]
        let byActivity = entries.sorted(by: .activity) { activity[$0.id] }
        #expect(byActivity.map(\.id) == [RepoGroup.entryID(zeta), web.key, api.key])
        #expect(byActivity.first?.repos.map(\.ref) == [cli, infra])
        #expect(entries.sorted(by: .custom) { _ in nil } == entries)
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

    @Test func groupLinksSearchAcrossRepositories() throws {
        let url = GitHubLinks.pullRequests([ref, RepoRef(owner: "octocat", name: "website")])
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/search")
        #expect(components.queryItems == [
            URLQueryItem(name: "q", value: "is:pr is:open repo:acme-org/payments repo:octocat/website"),
            URLQueryItem(name: "type", value: "pullrequests"),
        ])
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
