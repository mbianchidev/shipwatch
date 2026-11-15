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
    private var neverStartedCache: [Int: (updatedAt: Date, neverStarted: Bool)] = [:]
    /// Alert lists that answered 403 or 404, and when. Unlike 304s, those answers count against the rate limit.
    private var unreadableAlerts: [URL: Date] = [:]
    private let alertRetryInterval: TimeInterval = 15 * 60
    private let now: @Sendable () -> Date
    private let maxConcurrentRepoRequests = 6
    private var chunkSize = RepoQuery.chunkSize
    /// Repos in a row that failed even when queried alone: past this, GitHub is down rather than slow on one repo.
    private let maxConsecutiveRepoFailures = 3

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        api: URL = URL(string: "https://api.github.com")!,
        now: @escaping @Sendable () -> Date = { Date() },
        token: @escaping TokenProvider
    ) {
        self.transport = transport
        self.api = api
        self.now = now
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

    /// Fetches release, counts, activity and CI for every repo: one GraphQL call per chunk of repos,
    /// plus one conditional REST call per repo for workflow runs and one for the jobs of each new failure.
    /// With `securityAlerts`, the GraphQL call also counts open Dependabot alerts, and each repo gets one conditional
    /// REST call for code scanning alerts and one for secret scanning alerts.
    public func statuses(for refs: [RepoRef], includePrereleases: Bool, securityAlerts: Bool = false) async throws -> StatusBatch {
        var result: [String: RepoStatus] = [:]
        var progress = ChunkProgress()

        var remaining = refs[...]
        while !remaining.isEmpty {
            let chunk = Array(remaining.prefix(chunkSize))
            remaining = remaining.dropFirst(chunk.count)
            let statuses = try await repoStatuses(
                chunk, includePrereleases: includePrereleases, securityAlerts: securityAlerts, progress: &progress
            )
            for (ref, status) in zip(chunk, statuses) {
                result[ref.key] = status
            }
        }

        let readable = refs.compactMap { ref -> ReadableRepo? in
            guard let status = result[ref.key], status.problem == nil else { return nil }
            return ReadableRepo(key: ref.key, ref: status.ref, defaultBranch: status.defaultBranch)
        }
        let details = try await restDetails(for: readable, securityAlerts: securityAlerts)
        for (key, detail) in details {
            result[key]?.ci = detail.ci
            result[key]?.securityAlerts?.codeScanning = detail.codeScanning
            result[key]?.securityAlerts?.secretScanning = detail.secretScanning
        }
        return StatusBatch(statuses: result, rateLimit: progress.rateLimit)
    }

    /// Asks again right away for the alerts that couldn't be read, for example after access was granted.
    public func retryUnreadableAlerts() {
        unreadableAlerts = [:]
    }

    private struct ChunkProgress {
        var rateLimit: RateLimit?
        var consecutiveRepoFailures = 0
    }

    /// Splits a chunk in half when GitHub times out on it, so one slow batch or repo doesn't fail the whole refresh.
    /// A repo that still fails on its own shows the error on its row.
    private func repoStatuses(
        _ chunk: [RepoRef], includePrereleases: Bool, securityAlerts: Bool, progress: inout ChunkProgress
    ) async throws -> [RepoStatus] {
        do {
            let (query, variables) = RepoQuery.build(chunk, securityAlerts: securityAlerts)
            let data = try await graphQL(query: query, variables: variables)
            let parsed = try RepoQuery.parse(
                data, refs: chunk, includePrereleases: includePrereleases, securityAlerts: securityAlerts
            )
            progress.rateLimit = parsed.rateLimit ?? progress.rateLimit
            progress.consecutiveRepoFailures = 0
            return parsed.statuses
        } catch let error as GitHubError where error.isServerError {
            if chunk.count > 1 {
                log.notice("GraphQL query for \(chunk.count) repos failed, splitting it: \(error.localizedDescription, privacy: .public)")
                chunkSize = min(chunkSize, RepoQuery.smallChunkSize)
                let half = chunk.count / 2
                let first = try await repoStatuses(
                    Array(chunk[..<half]), includePrereleases: includePrereleases, securityAlerts: securityAlerts, progress: &progress
                )
                let second = try await repoStatuses(
                    Array(chunk[half...]), includePrereleases: includePrereleases, securityAlerts: securityAlerts, progress: &progress
                )
                return first + second
            }
            progress.consecutiveRepoFailures += 1
            if progress.consecutiveRepoFailures >= maxConsecutiveRepoFailures { throw error }
            log.error("GraphQL query for \(chunk[0].fullName, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
            return [RepoStatus(ref: chunk[0], problem: .error(error.localizedDescription))]
        }
    }

    private struct ReadableRepo: Sendable {
        var key: String
        var ref: RepoRef
        var defaultBranch: String?
    }

    private struct RepoDetails: Sendable {
        var ci: CISummary?
        var codeScanning: Int?
        var secretScanning: Int?
    }

    /// Reads workflow runs, and scanning alerts when asked, a few repos at a time.
    private func restDetails(for repos: [ReadableRepo], securityAlerts: Bool) async throws -> [String: RepoDetails] {
        try await withThrowingTaskGroup(of: (String, RepoDetails).self) { group in
            var details: [String: RepoDetails] = [:]
            var pending = repos.makeIterator()

            func addNext() {
                guard let repo = pending.next() else { return }
                group.addTask {
                    var detail = RepoDetails(ci: try await self.ciSummary(repo))
                    if securityAlerts {
                        detail.codeScanning = try await self.alertCountOrUnknown(repo.ref, .codeScanning)
                        detail.secretScanning = try await self.alertCountOrUnknown(repo.ref, .secretScanning)
                    }
                    return (repo.key, detail)
                }
            }

            for _ in 0..<maxConcurrentRepoRequests { addNext() }
            while let (key, detail) = try await group.next() {
                details[key] = detail
                addNext()
            }
            return details
        }
    }

    private func ciSummary(_ repo: ReadableRepo) async throws -> CISummary? {
        do {
            guard let runs = try await workflowRuns(repo.ref) else { return nil }
            let marked = try await markRunsThatNeverStarted(runs, ref: repo.ref, defaultBranch: repo.defaultBranch)
            return CIEvaluator.summarize(runs: marked, defaultBranch: repo.defaultBranch)
        } catch let error as GitHubError where error.affectsEveryRequest {
            throw error
        } catch {
            // One repo's Actions failing shouldn't hide everything else; its CI shows as unknown.
            return nil
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

    /// Reads the jobs of each workflow's latest failed run on the default branch, the runs that decide the state,
    /// and flags the runs whose jobs never started.
    private func markRunsThatNeverStarted(_ runs: [WorkflowRun], ref: RepoRef, defaultBranch: String?) async throws -> [WorkflowRun] {
        let candidates = CIEvaluator.summarize(runs: runs, defaultBranch: defaultBranch).latestOnDefault
            .filter { $0.conclusion == "failure" }
        var neverStarted = Set<Int>()
        for run in candidates {
            if try await jobsNeverStarted(run, ref: ref) { neverStarted.insert(run.id) }
        }
        guard !neverStarted.isEmpty else { return runs }
        return runs.map { run in
            var run = run
            run.jobsNeverStarted = neverStarted.contains(run.id)
            return run
        }
    }

    /// Cached per run until the run changes, for example when it is re-run, so each failure costs one request.
    private func jobsNeverStarted(_ run: WorkflowRun, ref: RepoRef) async throws -> Bool {
        if let cached = neverStartedCache[run.id], cached.updatedAt == run.updatedAt {
            return cached.neverStarted
        }
        do {
            let verdict = try await workflowJobs(ref, runID: run.id).map(CIEvaluator.neverStarted) ?? false
            neverStartedCache[run.id] = (run.updatedAt, verdict)
            return verdict
        } catch let error as GitHubError where error.affectsEveryRequest {
            throw error
        } catch {
            // The run then counts as a plain failure, which is what it showed before jobs were read.
            log.error("Jobs of workflow run \(run.id) could not be read: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The jobs of the run's latest attempt, or `nil` when they don't fit on one page.
    public func workflowJobs(_ ref: RepoRef, runID: Int) async throws -> [WorkflowJob]? {
        struct Page: Decodable {
            var totalCount: Int
            var jobs: [WorkflowJob]
        }
        let url = api.appending(path: "repos/\(ref.owner)/\(ref.name)/actions/runs/\(runID)/jobs")
            .appending(queryItems: [URLQueryItem(name: "per_page", value: "100")])
        let (data, _) = try await get(url)
        let page = try JSON.decode(Page.self, from: data)
        return page.totalCount > page.jobs.count ? nil : page.jobs
    }

    // MARK: Security alerts

    public enum ScanningAlertKind: String, Sendable {
        case codeScanning = "code-scanning"
        case secretScanning = "secret-scanning"
    }

    /// Open alerts of one kind, counted up to `SecurityAlerts.pageLimit`, or `nil` when the token can't read them.
    /// GitHub answers 403 or 404 without admin or security manager access, without GitHub Advanced Security on a
    /// private repo, or while the feature is off. Shipwatch then asks again only after `alertRetryInterval`.
    public func openAlertCount(_ ref: RepoRef, _ kind: ScanningAlertKind) async throws -> Int? {
        var query = [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "per_page", value: String(SecurityAlerts.pageLimit)),
        ]
        if kind == .secretScanning {
            // Only the count matters, so leaked secrets never reach Shipwatch.
            query.append(URLQueryItem(name: "hide_secret", value: "true"))
        }
        let url = api.appending(path: "repos/\(ref.owner)/\(ref.name)/\(kind.rawValue)/alerts").appending(queryItems: query)
        if let since = unreadableAlerts[url], now().timeIntervalSince(since) < alertRetryInterval {
            return nil
        }
        struct Alert: Decodable {}
        do {
            let (data, _) = try await get(url, conditional: true)
            unreadableAlerts[url] = nil
            return try JSON.decode([Alert].self, from: data).count
        } catch GitHubError.notFound {
            unreadableAlerts[url] = now()
            return nil
        } catch GitHubError.http(let status, _) where status == 403 {
            unreadableAlerts[url] = now()
            return nil
        }
    }

    /// One repo's alerts failing, for example with a 503, only leaves them unknown.
    private func alertCountOrUnknown(_ ref: RepoRef, _ kind: ScanningAlertKind) async throws -> Int? {
        do {
            return try await openAlertCount(ref, kind)
        } catch let error as GitHubError where error.affectsEveryRequest {
            throw error
        } catch {
            log.error("\(kind.rawValue, privacy: .public) alerts of \(ref.fullName, privacy: .private) could not be read: \(error.localizedDescription, privacy: .public)")
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
