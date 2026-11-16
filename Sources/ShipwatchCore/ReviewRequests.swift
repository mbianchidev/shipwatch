import Foundation

/// Whose review requests to count, and whether only those that still block merging.
public struct ReviewScope: Equatable, Sendable {
    public var login: String
    /// Only pull requests that can't be merged before an approving review (`reviewDecision` is `REVIEW_REQUIRED`).
    public var needingApproval: Bool

    public init(login: String, needingApproval: Bool) {
        self.login = login
        self.needingApproval = needingApproval
    }
}

/// Searches open pull requests waiting for a user's review, across every repository at once, and counts them per
/// repository. GitHub drops a request once the user reviews, so these are the ones still waiting.
enum ReviewRequestQuery {
    static let pageSize = 100
    /// Stops after this many pages; anyone with more than 500 open review requests sees a lower count.
    static let maxPages = 5

    static let query = """
    query($q: String!, $after: String) {
      search(query: $q, type: ISSUE, first: \(pageSize), after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes { ... on PullRequest { reviewDecision repository { nameWithOwner } } }
      }
    }
    """

    static func search(_ scope: ReviewScope) -> String {
        "is:pr is:open archived:false review-requested:\(scope.login)"
    }

    struct Page: Equatable {
        /// By `RepoRef.key`.
        var counts: [String: Int]
        var total: Int
        var nextCursor: String?
    }

    static func parse(_ data: Data, needingApproval: Bool) throws -> Page {
        let response = try JSON.decode(Response.self, from: data, snakeCase: false)
        guard let search = response.data?.search else {
            let message = response.errors?.map(\.message).joined(separator: "; ") ?? "empty response"
            throw GitHubError.graphQL(message)
        }
        var counts: [String: Int] = [:]
        for node in search.nodes {
            guard let name = node.repository?.nameWithOwner, let ref = RepoRef(parsing: name) else { continue }
            if needingApproval && node.reviewDecision != "REVIEW_REQUIRED" { continue }
            counts[ref.key, default: 0] += 1
        }
        let next = search.pageInfo.hasNextPage ? search.pageInfo.endCursor : nil
        return Page(counts: counts, total: search.issueCount, nextCursor: next)
    }

    struct Response: Decodable {
        var data: Body?
        var errors: [Message]?
    }

    struct Message: Decodable {
        var message: String
    }

    struct Body: Decodable {
        var search: Search?
    }

    struct Search: Decodable {
        var issueCount: Int
        var pageInfo: PageInfo
        var nodes: [Node]
    }

    struct PageInfo: Decodable {
        var hasNextPage: Bool
        var endCursor: String?
    }

    /// Empty for results that aren't pull requests.
    struct Node: Decodable {
        var reviewDecision: String?
        var repository: Repository?
    }

    struct Repository: Decodable {
        var nameWithOwner: String
    }
}
