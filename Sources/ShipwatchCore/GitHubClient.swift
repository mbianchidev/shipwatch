import Foundation

public struct StatusBatch: Sendable {
    /// Keyed by the requested `RepoRef.key`, so renamed repos still map back to the tracked entry.
    public var statuses: [String: RepoStatus]
    public var rateLimit: RateLimit?
}

public actor GitHubClient {
    public typealias TokenProvider = @Sendable () async throws -> String

    private let transport: any HTTPTransport
    private let api: URL
    private let token: TokenProvider
    private var etagCache: [URL: (etag: String, data: Data)] = [:]
    private let maxConcurrentRunRequests = 6

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        api: URL = URL(string: "https://api.github.com")!,
        token: @escaping TokenProvider
    ) {
        self.transport = transport
        self.api = api
        self.token = token
    }

    // MARK: Account

    public func currentUser() async throws -> GitHubUser {
        let (data, _) = try await get(api.appending(path: "user"))
        return try JSON.decode(GitHubUser.self, from: data)
    }

    /// Installations of GitHub Apps the user token can see. Only meaningful for GitHub App user tokens.
    public func installations() async throws -> [AppInstallation] {
        struct Page: Decodable { var installations: [AppInstallation] }
        let pages = try await paginate(api.appending(path: "user/installations"), as: Page.self)
        return pages.flatMap(\.installations)
    }

    public func installationRepositories(_ installationID: Int) async throws -> [RepoListing] {
        struct Page: Decodable { var repositories: [RepoListing] }
        let url = api.appending(path: "user/installations/\(installationID)/repositories")
        let pages = try await paginate(url, as: Page.self)
        return pages.flatMap(\.repositories)
    }

    /// Repositories the user owns, collaborates on, or can see through an organization.
    public func userRepositories() async throws -> [RepoListing] {
        let url = api.appending(path: "user/repos").appending(queryItems: [
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
            URLQueryItem(name: "sort", value: "pushed"),
        ])
        let pages = try await paginate(url, as: [RepoListing].self)
        return pages.flatMap { $0 }
    }

    // MARK: Status

    /// Fetches release, counts, activity and CI for every repo: one GraphQL call per chunk of 20,
    /// plus one conditional REST call per repo for workflow runs.
    public func statuses(for refs: [RepoRef], includePrereleases: Bool) async throws -> StatusBatch {
        var result: [String: RepoStatus] = [:]
        var rateLimit: RateLimit?

        for start in stride(from: 0, to: refs.count, by: RepoQuery.chunkSize) {
            let chunk = Array(refs[start..<min(start + RepoQuery.chunkSize, refs.count)])
            let (query, variables) = RepoQuery.build(chunk)
            let data = try await graphQL(query: query, variables: variables)
            let parsed = try RepoQuery.parse(data, refs: chunk, includePrereleases: includePrereleases)
            for (ref, status) in zip(chunk, parsed.statuses) {
                result[ref.key] = status
            }
            rateLimit = parsed.rateLimit ?? rateLimit
        }

        let readable = refs.compactMap { ref -> (key: String, ref: RepoRef, defaultBranch: String?)? in
            guard let status = result[ref.key], status.problem == nil else { return nil }
            return (key: ref.key, ref: status.ref, defaultBranch: status.defaultBranch)
        }
        let summaries = try await ciSummaries(for: readable)
        for (key, summary) in summaries {
            result[key]?.ci = summary
        }
        return StatusBatch(statuses: result, rateLimit: rateLimit)
    }

    private func ciSummaries(for repos: [(key: String, ref: RepoRef, defaultBranch: String?)]) async throws -> [String: CISummary] {
        try await withThrowingTaskGroup(of: (String, CISummary?).self) { group in
            var summaries: [String: CISummary] = [:]
            var pending = repos.makeIterator()

            func addNext() {
                guard let repo = pending.next() else { return }
                group.addTask {
                    do {
                        guard let runs = try await self.workflowRuns(repo.ref) else { return (repo.key, nil) }
                        return (repo.key, CIEvaluator.summarize(runs: runs, defaultBranch: repo.defaultBranch))
                    } catch let error as GitHubError where error.affectsEveryRequest {
                        throw error
                    } catch {
                        // One repo's Actions failing shouldn't hide everything else; its CI shows as unknown.
                        return (repo.key, nil)
                    }
                }
            }

            for _ in 0..<maxConcurrentRunRequests { addNext() }
            while let (key, summary) = try await group.next() {
                if let summary { summaries[key] = summary }
                addNext()
            }
            return summaries
        }
    }

    /// The 50 most recent runs, or `nil` when the token can't read Actions for this repo.
    public func workflowRuns(_ ref: RepoRef) async throws -> [WorkflowRun]? {
        struct Page: Decodable { var workflowRuns: [WorkflowRun] }
        let url = api.appending(path: "repos/\(ref.owner)/\(ref.name)/actions/runs")
            .appending(queryItems: [URLQueryItem(name: "per_page", value: "50")])
        do {
            let (data, _) = try await get(url, conditional: true)
            return try JSON.decode(Page.self, from: data).workflowRuns
        } catch GitHubError.notFound {
            return nil
        } catch GitHubError.http(let status, _) where status == 403 {
            return nil
        }
    }

    // MARK: Transport

    func graphQL(query: String, variables: [String: String]) async throws -> Data {
        var request = try await authorizedRequest(api.appending(path: "graphql"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await transport.send(request)
        try check(response, data: data)
        return data
    }

    private func get(_ url: URL, conditional: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var request = try await authorizedRequest(url)
        let cached = conditional ? etagCache[url] : nil
        if let cached {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await transport.send(request)
        if response.statusCode == 304, let cached {
            return (cached.data, response)
        }
        try check(response, data: data)
        if conditional, let etag = response.header("ETag") {
            etagCache[url] = (etag, data)
        }
        return (data, response)
    }

    private func paginate<Page: Decodable>(_ first: URL, as type: Page.Type, maxPages: Int = 10) async throws -> [Page] {
        var pages: [Page] = []
        var next: URL? = first.appending(queryItems: [URLQueryItem(name: "per_page", value: "100")])
        while let url = next, pages.count < maxPages {
            let (data, response) = try await get(url)
            pages.append(try JSON.decode(Page.self, from: data))
            next = response.nextPageURL
        }
        return pages
    }

    private func authorizedRequest(_ url: URL) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func check(_ response: HTTPURLResponse, data: Data) throws {
        if (200..<300).contains(response.statusCode) { return }
        if let limited = response.rateLimitError() { throw limited }
        switch response.statusCode {
        case 401: throw GitHubError.unauthorized
        case 404: throw GitHubError.notFound
        default:
            struct Message: Decodable { var message: String? }
            let message = (try? JSONDecoder().decode(Message.self, from: data))?.message
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw GitHubError.http(status: response.statusCode, message: message)
        }
    }
}
