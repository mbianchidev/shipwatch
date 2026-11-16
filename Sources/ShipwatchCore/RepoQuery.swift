import Foundation

/// Builds and parses the batched GraphQL query that fetches everything except workflow runs and scanning alerts.
/// Values go through GraphQL variables, so repository names never get spliced into the query text.
enum RepoQuery {
    /// GitHub answers 502 when a GraphQL query runs too long, and each repo adds a search, so batches stay small.
    static let chunkSize = 10
    /// Used for later refreshes once a batch timed out.
    static let smallChunkSize = 5

    /// Open Dependabot alerts come back `null`, with a `FORBIDDEN` error, when the token can't read them.
    static func fragment(securityAlerts: Bool) -> String {
        """
        fragment RepoFields on Repository {
          nameWithOwner url isPrivate isArchived pushedAt
          defaultBranchRef { name target { oid } }
          latestRelease { tagName url publishedAt isPrerelease }
          releases(first: 10, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { tagName url publishedAt isPrerelease isDraft } }
          issues(states: OPEN) { totalCount }
          pullRequests(states: OPEN) { totalCount }
          recentIssue: issues(first: 1, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { updatedAt } }
          recentPullRequest: pullRequests(first: 1, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { updatedAt } }
        \(securityAlerts ? "  vulnerabilityAlerts(states: OPEN) { totalCount }\n" : "")}
        """
    }

    static func dependabotSearch(_ ref: RepoRef, assignee: String? = nil) -> String {
        "repo:\(ref.fullName) is:pr is:open author:app/dependabot" + (assignee.map { " assignee:\($0)" } ?? "")
    }

    static func assignedPullRequestSearch(_ ref: RepoRef, assignee: String) -> String {
        "repo:\(ref.fullName) is:pr is:open assignee:\(assignee)"
    }

    /// Repositories in `mine` also count the open issues assigned to its login, and search the pull requests
    /// assigned to it, which `pullRequests` can't filter by.
    static func build(
        _ refs: [RepoRef], securityAlerts: Bool = false, mine: MineScope? = nil
    ) -> (query: String, variables: [String: String]) {
        var declarations: [String] = []
        var fields: [String] = ["  rateLimit { remaining resetAt }"]
        var variables: [String: String] = [:]
        for (index, ref) in refs.enumerated() {
            let assignee = mine?.login(for: ref)
            declarations.append("$o\(index): String!, $n\(index): String!, $q\(index): String!")
            if let assignee {
                declarations.append("$p\(index): String!")
                fields.append("  r\(index): repository(owner: $o\(index), name: $n\(index)) { ...RepoFields assignedIssues: issues(states: OPEN, filterBy: {assignee: $me}) { totalCount } }")
                fields.append("  p\(index): search(query: $p\(index), type: ISSUE, first: 0) { issueCount }")
                variables["p\(index)"] = assignedPullRequestSearch(ref, assignee: assignee)
                variables["me"] = assignee
            } else {
                fields.append("  r\(index): repository(owner: $o\(index), name: $n\(index)) { ...RepoFields }")
            }
            fields.append("  d\(index): search(query: $q\(index), type: ISSUE, first: 0) { issueCount }")
            variables["o\(index)"] = ref.owner
            variables["n\(index)"] = ref.name
            variables["q\(index)"] = dependabotSearch(ref, assignee: assignee)
        }
        // GraphQL rejects declared variables that no field uses.
        if variables["me"] != nil { declarations.append("$me: String!") }
        let query = "query(\(declarations.joined(separator: ", "))) {\n\(fields.joined(separator: "\n"))\n}\n\(fragment(securityAlerts: securityAlerts))"
        return (query, variables)
    }

    static func parse(
        _ data: Data, refs: [RepoRef], includePrereleases: Bool, securityAlerts: Bool = false, mine: MineScope? = nil
    ) throws -> (statuses: [RepoStatus], rateLimit: RateLimit?) {
        let response = try JSON.decode(Response.self, from: data, snakeCase: false)
        guard let body = response.data else {
            let message = response.errors?.map(\.message).joined(separator: "; ") ?? "empty response"
            throw GitHubError.graphQL(message)
        }

        var errorsByAlias: [String: GraphQLError] = [:]
        for error in response.errors ?? [] {
            if let alias = error.path?.first { errorsByAlias[alias] = error }
        }

        let statuses = refs.enumerated().map { index, ref -> RepoStatus in
            guard let node = body.repositories[index] else {
                if let error = errorsByAlias["r\(index)"], !["NOT_FOUND", "FORBIDDEN"].contains(error.type ?? "") {
                    return RepoStatus(ref: ref, problem: .error(error.message))
                }
                return RepoStatus(ref: ref, problem: .noAccess)
            }
            var status = node.status(for: ref, dependabot: body.dependabotCounts[index] ?? 0, includePrereleases: includePrereleases)
            if let login = mine?.login(for: ref) {
                let assignedPullRequests = body.assignedPullRequests[index] ?? 0
                status.openIssues = node.assignedIssues?.totalCount ?? 0
                status.openPullRequests = assignedPullRequests
                status.dependabotPullRequests = min(body.dependabotCounts[index] ?? 0, assignedPullRequests)
                status.onlyMine = login
            }
            if securityAlerts {
                status.securityAlerts = SecurityAlerts(dependabot: node.vulnerabilityAlerts?.totalCount)
            }
            return status
        }
        let rateLimit = body.rateLimit.map { RateLimit(remaining: $0.remaining, resetAt: $0.resetAt) }
        return (statuses, rateLimit)
    }

    struct Response: Decodable {
        var data: Body?
        var errors: [GraphQLError]?
    }

    struct GraphQLError: Decodable {
        var type: String?
        var message: String
        var path: [String]?

        enum CodingKeys: String, CodingKey { case type, message, path }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            message = try container.decode(String.self, forKey: .message)
            // Paths mix strings and list indexes; only the leading alias matters here.
            var elements: [String] = []
            if var path = try? container.nestedUnkeyedContainer(forKey: .path) {
                while !path.isAtEnd {
                    if let text = try? path.decode(String.self) {
                        elements.append(text)
                    } else if let number = try? path.decode(Int.self) {
                        elements.append(String(number))
                    } else {
                        break
                    }
                }
            }
            path = elements.isEmpty ? nil : elements
        }
    }

    struct Body: Decodable {
        var rateLimit: RateLimitNode?
        var repositories: [Int: RepoNode] = [:]
        var dependabotCounts: [Int: Int] = [:]
        var assignedPullRequests: [Int: Int] = [:]

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            for key in container.allKeys {
                let name = key.stringValue
                if name == "rateLimit" {
                    rateLimit = try container.decodeIfPresent(RateLimitNode.self, forKey: key)
                } else if name.hasPrefix("r"), let index = Int(name.dropFirst()) {
                    repositories[index] = try container.decodeIfPresent(RepoNode.self, forKey: key)
                } else if name.hasPrefix("d"), let index = Int(name.dropFirst()) {
                    dependabotCounts[index] = try container.decodeIfPresent(SearchCount.self, forKey: key)?.issueCount
                } else if name.hasPrefix("p"), let index = Int(name.dropFirst()) {
                    assignedPullRequests[index] = try container.decodeIfPresent(SearchCount.self, forKey: key)?.issueCount
                }
            }
        }
    }

    struct RateLimitNode: Decodable {
        var remaining: Int
        var resetAt: Date
    }

    struct SearchCount: Decodable {
        var issueCount: Int
    }

    struct Count: Decodable {
        var totalCount: Int
    }

    struct Nodes<T: Decodable>: Decodable {
        var nodes: [T]
    }

    struct Updated: Decodable {
        var updatedAt: Date
    }

    struct BranchRef: Decodable {
        struct Target: Decodable {
            var oid: String
        }

        var name: String
        var target: Target?
    }

    struct ReleaseNode: Decodable {
        var tagName: String
        var url: URL
        var publishedAt: Date?
        var isPrerelease: Bool
        var isDraft: Bool?

        var release: Release {
            Release(tagName: tagName, url: url, publishedAt: publishedAt, isPrerelease: isPrerelease)
        }
    }

    struct RepoNode: Decodable {
        var nameWithOwner: String
        var url: URL
        var isPrivate: Bool
        var isArchived: Bool
        var pushedAt: Date?
        var defaultBranchRef: BranchRef?
        var latestRelease: ReleaseNode?
        var releases: Nodes<ReleaseNode>
        var issues: Count
        var pullRequests: Count
        var recentIssue: Nodes<Updated>
        var recentPullRequest: Nodes<Updated>
        var vulnerabilityAlerts: Count?
        var assignedIssues: Count?

        func status(for ref: RepoRef, dependabot: Int, includePrereleases: Bool) -> RepoStatus {
            // `latestRelease` skips pre-releases and drafts; with pre-releases on, take the newest published one.
            let release: Release?
            if includePrereleases {
                release = releases.nodes.first { $0.isDraft != true }?.release ?? latestRelease?.release
            } else {
                release = latestRelease?.release
            }
            let canonical = RepoRef(parsing: nameWithOwner) ?? ref
            return RepoStatus(
                ref: canonical,
                url: url,
                isPrivate: isPrivate,
                isArchived: isArchived,
                defaultBranch: defaultBranchRef?.name,
                defaultBranchHead: defaultBranchRef?.target?.oid,
                latestRelease: release,
                openIssues: issues.totalCount,
                openPullRequests: pullRequests.totalCount,
                dependabotPullRequests: min(dependabot, pullRequests.totalCount),
                pushedAt: pushedAt,
                lastIssueUpdate: recentIssue.nodes.first?.updatedAt,
                lastPullRequestUpdate: recentPullRequest.nodes.first?.updatedAt
            )
        }
    }
}
