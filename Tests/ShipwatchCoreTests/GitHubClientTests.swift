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
        #expect(api.defaultBranchHead == "9f1c2e7a4b3d5e6f708192a3b4c5d6e7f8091a2b")
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

    @Test func countsDependabotAlertsOnlyWhenAsked() throws {
        #expect(!RepoQuery.build(refs).query.contains("vulnerabilityAlerts"))
        #expect(RepoQuery.build(refs, securityAlerts: true).query.contains("vulnerabilityAlerts(states: OPEN) { totalCount }"))

        let json = """
        {"data":{"r0":\(Fixtures.repoNode("mbianchidev/api-server", vulnerabilityAlerts: #"{"totalCount":3}"#)),"d0":{"issueCount":0},
          "r1":\(Fixtures.repoNode("acme-org/legacy-api", vulnerabilityAlerts: "null")),"d1":{"issueCount":0}},
         "errors":[{"type":"FORBIDDEN","path":["r1","vulnerabilityAlerts"],"message":"Resource not accessible by integration"}]}
        """
        let statuses = try RepoQuery.parse(Data(json.utf8), refs: refs, includePrereleases: false, securityAlerts: true).statuses
        #expect(statuses[0].securityAlerts == SecurityAlerts(dependabot: 3))
        #expect(statuses[1].problem == nil)
        #expect(statuses[1].securityAlerts == SecurityAlerts(dependabot: nil))
        let off = try RepoQuery.parse(Data(json.utf8), refs: refs, includePrereleases: false).statuses
        #expect(off[0].securityAlerts == nil)
    }

    @Test func mineCountsOnlyWhatIsAssigned() throws {
        let mine = MineScope(login: "octocat", keys: [refs[0].key])
        let (query, variables) = RepoQuery.build(refs, mine: mine)
        #expect(query.contains("r0: repository(owner: $o0, name: $n0) { ...RepoFields assignedIssues: issues(states: OPEN, filterBy: {assignee: $me}) { totalCount } }"))
        #expect(query.contains("r1: repository(owner: $o1, name: $n1) { ...RepoFields }"))
        #expect(query.contains("$p0: String!") && query.contains("$me: String!") && !query.contains("$p1"))
        #expect(variables["me"] == "octocat")
        #expect(variables["p0"] == "repo:mbianchidev/api-server is:pr is:open assignee:octocat")
        #expect(variables["q0"] == "repo:mbianchidev/api-server is:pr is:open author:app/dependabot assignee:octocat")
        #expect(variables["q1"] == "repo:acme-org/legacy-api is:pr is:open author:app/dependabot")
        #expect(!RepoQuery.build(refs).query.contains("$me"))

        let node = String(Fixtures.repoNode("mbianchidev/api-server").dropLast()) + #","assignedIssues":{"totalCount":1}}"#
        let json = """
        {"data":{"r0":\(node),"p0":{"issueCount":2},"d0":{"issueCount":3},
          "r1":\(Fixtures.repoNode("acme-org/legacy-api")),"d1":{"issueCount":5}}}
        """
        let statuses = try RepoQuery.parse(Data(json.utf8), refs: refs, includePrereleases: false, mine: mine).statuses
        let counts = statuses.map { [$0.openIssues, $0.openPullRequests, $0.dependabotPullRequests] }
        #expect(counts == [[1, 2, 2], [4, 11, 5]])
        #expect(statuses.map(\.onlyMine) == ["octocat", nil])
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
        #expect(api.securityAlerts == nil)
        #expect(batch.rateLimit?.remaining == 4990)
        #expect(transport.requests.count == 2)
    }

    @Test func mineAsksOnlyForRunsTheUserTriggered() async throws {
        let transport = MockTransport { request in
            if request.url!.path == "/graphql" {
                #expect(request.bodyString.contains("assignedIssues"))
                return .json(Self.graphQL)
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "actor", value: "octocat")))
            return .json(Self.runs)
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        let mine = MineScope(login: "octocat", keys: [Self.api.key])
        let batch = try await client.statuses(for: [Self.api, Self.legacy], includePrereleases: false, mine: mine)
        #expect(batch.statuses[Self.api.key]?.onlyMine == "octocat")
        #expect(transport.requests.count == 2)
    }

    static func reviewPage(_ nodes: [(repo: String, decision: String?)], next: String? = nil) -> String {
        let items = nodes.map { node in
            #"{"reviewDecision":\#(node.decision.map { "\"\($0)\"" } ?? "null"),"repository":{"nameWithOwner":"\#(node.repo)"}}"#
        } + ["{}"]
        let cursor = next.map { "\"\($0)\"" } ?? "null"
        return #"{"data":{"search":{"issueCount":\#(nodes.count),"pageInfo":{"hasNextPage":\#(next != nil),"endCursor":\#(cursor)},"nodes":[\#(items.joined(separator: ","))]}}}"#
    }

    @Test func countsReviewRequestsPerRepoAcrossPages() async throws {
        let transport = MockTransport { request in
            let body = request.bodyString
            if body.contains("RepoFields") { return .json(Self.graphQL) }
            if request.url!.path != "/graphql" { return .json(Self.runs) }
            #expect(body.contains("is:pr is:open archived:false review-requested:octocat"))
            if body.contains("page-2") {
                return .json(Self.reviewPage([(repo: "MBianchiDev/API-Server", decision: "APPROVED")]))
            }
            return .json(Self.reviewPage([
                (repo: "mbianchidev/api-server", decision: "REVIEW_REQUIRED"), (repo: "octocat/elsewhere", decision: nil),
            ], next: "page-2"))
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        let all = try await client.reviewRequests(ReviewScope(login: "octocat", needingApproval: false))
        #expect(all == [Self.api.key: 2, "octocat/elsewhere": 1])
        let blocking = try await client.reviewRequests(ReviewScope(login: "octocat", needingApproval: true))
        #expect(blocking == [Self.api.key: 1])

        let batch = try await client.statuses(
            for: [Self.api, Self.legacy], includePrereleases: false, reviews: ReviewScope(login: "octocat", needingApproval: false)
        )
        #expect(batch.statuses[Self.api.key]?.reviewRequests == 2)
        #expect(batch.statuses[Self.legacy.key]?.reviewRequests == nil)
    }

    @Test func failingReviewSearchOnlyLeavesItsCountsUnknown() async throws {
        let transport = MockTransport { request in
            if request.bodyString.contains("RepoFields") { return .json(Self.graphQL) }
            if request.url!.path == "/graphql" { return .json(#"{"errors":[{"message":"Something went wrong"}]}"#) }
            return .json(Self.runs)
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        let batch = try await client.statuses(
            for: [Self.api], includePrereleases: false, reviews: ReviewScope(login: "octocat", needingApproval: false)
        )
        #expect(batch.statuses[Self.api.key]?.ci?.state == .running)
        #expect(batch.statuses[Self.api.key]?.reviewRequests == nil)
    }

    static let codeScanningPath = "/repos/mbianchidev/api-server/code-scanning/alerts"
    static let secretScanningPath = "/repos/mbianchidev/api-server/secret-scanning/alerts"

    @Test func securityAlertsCombineGraphQLAndScanningCounts() async throws {
        let transport = MockTransport { request in
            switch request.url!.path {
            case "/graphql":
                #expect(request.bodyString.contains("vulnerabilityAlerts"))
                let node = Fixtures.repoNode("mbianchidev/api-server", vulnerabilityAlerts: #"{"totalCount":2}"#)
                return .json(#"{"data":{"r0":\#(node),"d0":{"issueCount":0}}}"#)
            case Self.codeScanningPath:
                if request.value(forHTTPHeaderField: "If-None-Match") == "\"cs\"" { return MockTransport.Reply(status: 304, body: Data()) }
                return .json(#"[{"number":7},{"number":5},{"number":4}]"#, headers: ["ETag": "\"cs\""])
            case Self.secretScanningPath:
                return .json(#"{"message":"Not Found"}"#, status: 404)
            default:
                return .json(Self.runs)
            }
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        for _ in 0..<2 {
            let batch = try await client.statuses(for: [Self.api], includePrereleases: false, securityAlerts: true)
            let alerts = try #require(batch.statuses[Self.api.key]?.securityAlerts)
            #expect(alerts == SecurityAlerts(dependabot: 2, codeScanning: 3, secretScanning: nil))
            #expect(alerts.total == 5)
            #expect(!alerts.isComplete)
        }
        let paths = transport.requests.map { $0.url!.path }
        #expect(paths.filter { $0 == Self.codeScanningPath }.count == 2)
        // A 404 counts against the rate limit, so it isn't asked again on the next refresh.
        #expect(paths.filter { $0 == Self.secretScanningPath }.count == 1)
        let secret = try #require(transport.requests.first { $0.url!.path == Self.secretScanningPath }?.url)
        let query = URLComponents(url: secret, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "state", value: "open")))
        #expect(query.contains(URLQueryItem(name: "hide_secret", value: "true")))
    }

    @Test func unreadableAlertsAreAskedAgainLater() async throws {
        let transport = MockTransport { _ in
            .json(#"{"message":"Advanced Security must be enabled for this repository to use code scanning."}"#, status: 403)
        }
        let clock = Clock(Fixtures.now)
        let client = GitHubClient(transport: transport, now: { clock.now }, token: { "test-token" })
        #expect(try await client.openAlertCount(Self.api, .codeScanning) == nil)
        clock.advance(10 * 60)
        #expect(try await client.openAlertCount(Self.api, .codeScanning) == nil)
        #expect(transport.requests.count == 1)
        clock.advance(6 * 60)
        _ = try await client.openAlertCount(Self.api, .codeScanning)
        #expect(transport.requests.count == 2)
        await client.retryUnreadableAlerts()
        _ = try await client.openAlertCount(Self.api, .codeScanning)
        #expect(transport.requests.count == 3)
    }

    @Test func failingScanningAlertsLeaveTheRestOfTheRow() async throws {
        let transport = MockTransport { request in
            switch request.url!.path {
            case "/graphql": return Self.graphQLReply(["mbianchidev/api-server"])
            case Self.codeScanningPath, Self.secretScanningPath: return Self.gatewayTimeout
            default: return .json(Self.runs)
            }
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        let batch = try await client.statuses(for: [Self.api], includePrereleases: false, securityAlerts: true)
        let api = try #require(batch.statuses[Self.api.key])
        #expect(api.ci?.state == .running)
        #expect(api.securityAlerts == SecurityAlerts(dependabot: nil, codeScanning: nil, secretScanning: nil))
    }

    static let payments = RepoRef(owner: "acme-org", name: "payments")
    static let infra = RepoRef(owner: "acme-org", name: "infra")

    /// The repos a GraphQL request asks for, in alias order.
    static func requestedRepos(_ request: URLRequest) -> [String] {
        struct Body: Decodable { var variables: [String: String] }
        guard let data = request.httpBody, let body = try? JSONDecoder().decode(Body.self, from: data) else { return [] }
        return (0..<body.variables.count / 3).map { "\(body.variables["o\($0)"]!)/\(body.variables["n\($0)"]!)" }
    }

    static func graphQLReply(_ repos: [String]) -> MockTransport.Reply {
        let fields = repos.enumerated().map { #""r\#($0.offset)":\#(Fixtures.repoNode($0.element)),"d\#($0.offset)":{"issueCount":0}"# }
        return .json(#"{"data":{\#(fields.joined(separator: ","))}}"#)
    }

    static let gatewayTimeout = MockTransport.Reply.json(#"{"message":"Server Error"}"#, status: 502)

    @Test func splitsQueriesThatTimeOut() async throws {
        let transport = MockTransport { request in
            guard request.url!.path == "/graphql" else { return .json(Self.runs) }
            let repos = Self.requestedRepos(request)
            return repos.count > 1 ? Self.gatewayTimeout : Self.graphQLReply(repos)
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        let batch = try await client.statuses(for: [Self.api, Self.payments], includePrereleases: false)

        #expect(batch.statuses[Self.api.key]?.problem == nil)
        #expect(batch.statuses[Self.payments.key]?.ci?.state == .running)
        let queries = transport.requests.filter { $0.url!.path == "/graphql" }.map(Self.requestedRepos)
        #expect(queries == [["mbianchidev/api-server", "acme-org/payments"], ["mbianchidev/api-server"], ["acme-org/payments"]])
    }

    @Test func repoThatTimesOutAloneShowsTheErrorOnItsRow() async throws {
        let transport = MockTransport { request in
            guard request.url!.path == "/graphql" else { return .json(Self.runs) }
            let repos = Self.requestedRepos(request)
            return repos.contains("mbianchidev/api-server") ? Self.gatewayTimeout : Self.graphQLReply(repos)
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        let batch = try await client.statuses(for: [Self.api, Self.payments, Self.infra], includePrereleases: false)

        #expect(batch.statuses[Self.api.key]?.problem == .error("GitHub returned HTTP 502: Server Error"))
        #expect(batch.statuses[Self.api.key]?.ci == nil)
        #expect(batch.statuses[Self.payments.key]?.problem == nil)
        #expect(batch.statuses[Self.infra.key]?.problem == nil)
        #expect(!transport.requests.contains { $0.url!.path == "/repos/mbianchidev/api-server/actions/runs" })
    }

    @Test func outageStillFailsTheRefresh() async throws {
        let transport = MockTransport { _ in Self.gatewayTimeout }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        await #expect(throws: GitHubError.http(status: 502, message: "Server Error")) {
            try await client.statuses(for: [Self.api, Self.payments, Self.infra, Self.legacy], includePrereleases: false)
        }
        #expect(transport.requests.count <= 6)
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

    static let failedRuns = Fixtures.runsJSON([
        (id: 490, workflow: 1, status: "completed", conclusion: "failure", branch: "main", created: "2026-11-14T15:30:00Z"),
        (id: 489, workflow: 2, status: "completed", conclusion: "failure", branch: "feature", created: "2026-11-14T15:20:00Z"),
    ])

    @Test func failedRunWhoseJobsNeverStartedIsNotStartedAndReadOnce() async throws {
        let transport = MockTransport { request in
            switch request.url!.path {
            case "/graphql": return Self.graphQLReply(["mbianchidev/api-server"])
            case "/repos/mbianchidev/api-server/actions/runs": return .json(Self.failedRuns)
            case "/repos/mbianchidev/api-server/actions/runs/490/jobs": return .json(Fixtures.jobsNeverStartedJSON)
            default: return .json(#"{"message":"Not Found"}"#, status: 404)
            }
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        for _ in 0..<2 {
            let batch = try await client.statuses(for: [Self.api], includePrereleases: false)
            let ci = try #require(batch.statuses[Self.api.key]?.ci)
            #expect(ci.state == .notStarted)
            #expect(ci.primaryRun?.didNotStart == true)
        }
        let jobRequests = transport.requests.filter { $0.url!.path.hasSuffix("/jobs") }
        #expect(jobRequests.map { $0.url!.path } == ["/repos/mbianchidev/api-server/actions/runs/490/jobs"])
    }

    @Test func unreadableJobsLeaveTheRunFailing() async throws {
        let transport = MockTransport { request in
            switch request.url!.path {
            case "/graphql": return Self.graphQLReply(["mbianchidev/api-server"])
            case "/repos/mbianchidev/api-server/actions/runs": return .json(Self.failedRuns)
            default: return Self.gatewayTimeout
            }
        }
        let client = GitHubClient(transport: transport, token: { "test-token" })
        let batch = try await client.statuses(for: [Self.api], includePrereleases: false)
        #expect(batch.statuses[Self.api.key]?.ci?.state == .failing)
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
