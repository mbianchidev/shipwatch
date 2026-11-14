import Foundation
import Testing
@testable import ShipwatchCore

struct RepoQueryTests {
    let refs = [RepoRef(owner: "mbianchidev", name: "api-server"), RepoRef(owner: "acme-org", name: "legacy-api")]

    @Test func usesVariablesInsteadOfSplicingNames() {
        let (query, variables) = RepoQuery.build(refs)
        #expect(query.contains("r1: repository(owner: $o1, name: $n1) { ...RepoFields }"))
        #expect(query.contains("d0: search(query: $q0, type: ISSUE, first: 0) { issueCount }"))
        #expect(!query.contains("api-server"))
        #expect(variables["n0"] == "api-server")
        #expect(variables["q1"] == "repo:acme-org/legacy-api is:pr is:open author:app/dependabot")
    }

    @Test func parsesReposAndMissingAccess() throws {
        let json = """
        {"data":{"rateLimit":{"remaining":4990,"resetAt":"2026-11-14T16:00:00Z"},
          "r0":\(Fixtures.repoNode("mbianchidev/api-server", isPrivate: true)),"d0":{"issueCount":5},
          "r1":null,"d1":{"issueCount":0}},
         "errors":[{"type":"NOT_FOUND","path":["r1"],"message":"Could not resolve to a Repository"}]}
        """
        let (statuses, rateLimit) = try RepoQuery.parse(Data(json.utf8), refs: refs, includePrereleases: false)
        #expect(rateLimit?.remaining == 4990)
        let api = statuses[0]
        #expect(api.isPrivate)
        #expect(api.defaultBranch == "main")
        #expect(api.latestRelease?.tagName == "v2.4.1")
        #expect(api.openIssues == 4)
        #expect(api.openPullRequests == 11)
        #expect(api.dependabotPullRequests == 5)
        #expect(api.lastPullRequestUpdate == Fixtures.date("2026-11-14T15:39:00Z"))
        #expect(statuses[1].problem == .noAccess)
    }

    @Test func otherErrorsAreReportedPerRepo() throws {
        let json = """
        {"data":{"r0":null,"d0":null,"r1":null,"d1":null},
         "errors":[{"type":"SERVICE_UNAVAILABLE","path":["r0","releases",0],"message":"Timeout"}]}
        """
        let (statuses, _) = try RepoQuery.parse(Data(json.utf8), refs: refs, includePrereleases: false)
        #expect(statuses[0].problem == .error("Timeout"))
        #expect(statuses[1].problem == .noAccess)
    }

    @Test func prereleasesOnlyWhenEnabled() throws {
        let one = [RepoRef(owner: "acme-org", name: "payments")]
        let json = """
        {"data":{"r0":\(Fixtures.repoNode("acme-org/payments", releaseTag: "v2.9.0", prerelease: "v3.0.0-rc.2")),"d0":{"issueCount":5}}}
        """
        let stable = try RepoQuery.parse(Data(json.utf8), refs: one, includePrereleases: false).statuses[0]
        #expect(stable.latestRelease?.tagName == "v2.9.0")
        let pre = try RepoQuery.parse(Data(json.utf8), refs: one, includePrereleases: true).statuses[0]
        #expect(pre.latestRelease?.tagName == "v3.0.0-rc.2")
        #expect(pre.latestRelease?.isPrerelease == true)
    }

    @Test func wholeQueryFailureThrows() {
        let json = #"{"errors":[{"message":"Bad credentials"}]}"#
        #expect(throws: GitHubError.graphQL("Bad credentials")) {
            try RepoQuery.parse(Data(json.utf8), refs: refs, includePrereleases: false)
        }
    }
}

struct GitHubClientTests {
    static let api = RepoRef(owner: "mbianchidev", name: "api-server")
    static let legacy = RepoRef(owner: "acme-org", name: "legacy-api")

    static let graphQL = """
    {"data":{"rateLimit":{"remaining":4990,"resetAt":"2026-11-14T16:00:00Z"},
      "r0":\(Fixtures.repoNode("mbianchidev/api-server")),"d0":{"issueCount":5},"r1":null,"d1":{"issueCount":0}},
     "errors":[{"type":"NOT_FOUND","path":["r1"],"message":"Could not resolve"}]}
    """

    static let runs = Fixtures.runsJSON([
        (id: 482, workflow: 1, status: "in_progress", conclusion: nil, branch: "main", created: "2026-11-14T15:37:00Z"),
        (id: 481, workflow: 1, status: "completed", conclusion: "success", branch: "main", created: "2026-11-14T13:00:00Z"),
    ])

    @Test func combinesGraphQLAndRunsAndSkipsUnreadableRepos() async throws {
        let transport = MockTransport { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            if request.url!.path == "/graphql" { return .json(Self.graphQL) }
            #expect(request.url!.path == "/repos/mbianchidev/api-server/actions/runs")
            return .json(Self.runs, headers: ["ETag": "\"abc\""])
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        let batch = try await client.statuses(for: [Self.api, Self.legacy], includePrereleases: false)

        let api = try #require(batch.statuses[Self.api.key])
        #expect(api.ci?.state == .running)
        #expect(api.ci?.running.first?.id == 482)
        #expect(batch.statuses[Self.legacy.key]?.problem == .noAccess)
        #expect(batch.statuses[Self.legacy.key]?.ci == nil)
        #expect(batch.rateLimit?.remaining == 4990)
        #expect(transport.requests.count == 2)
    }

    @Test func sendsETagAndReusesCachedRunsOn304() async throws {
        let transport = MockTransport { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"" {
                return MockTransport.Reply(status: 304, body: Data())
            }
            return .json(Self.runs, headers: ["ETag": "\"abc\""])
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        let first = try await client.workflowRuns(Self.api)
        let second = try await client.workflowRuns(Self.api)
        #expect(first?.count == 2)
        #expect(second == first)
        #expect(transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
    }

    @Test func missingActionsAccessIsUnknownCI() async throws {
        let transport = MockTransport { _ in .json(#"{"message":"Not Found"}"#, status: 404) }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        #expect(try await client.workflowRuns(Self.api) == nil)
    }

    @Test func rateLimitIsReportedWithResetTime() async throws {
        let transport = MockTransport { _ in
            .json(#"{"message":"API rate limit exceeded"}"#, status: 403, headers: [
                "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1794671520",
            ])
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        await #expect(throws: GitHubError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_794_671_520))) {
            try await client.statuses(for: [Self.api], includePrereleases: false)
        }
    }

    @Test func unauthorizedIsDistinct() async throws {
        let transport = MockTransport { _ in .json(#"{"message":"Bad credentials"}"#, status: 401) }
        let client = GitHubClient(transport: transport, token: { "expired" })
        await #expect(throws: GitHubError.unauthorized) { try await client.currentUser() }
    }

    @Test func followsPaginationLinks() async throws {
        let transport = MockTransport { request in
            let page2 = "https://api.github.com/user/installations/7/repositories?per_page=100&page=2"
            if request.url!.absoluteString == page2 {
                return .json(#"{"repositories":[{"name":"payments","owner":{"login":"acme-org"},"private":true,"pushed_at":"2026-11-14T10:00:00Z"}]}"#)
            }
            return .json(
                #"{"repositories":[{"name":"infra","owner":{"login":"acme-org"},"private":false,"pushed_at":null}]}"#,
                headers: ["Link": "<\(page2)>; rel=\"next\", <\(page2)>; rel=\"last\""]
            )
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        let repos = try await client.installationRepositories(7)
        #expect(repos.map(\.ref.fullName) == ["acme-org/infra", "acme-org/payments"])
        #expect(repos[1].private)
    }
}
