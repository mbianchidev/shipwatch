import Foundation

/// A GitHub repository identified by `owner/name`.
public struct RepoRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Accepts `owner/name`, `github.com/owner/name`, `https://github.com/owner/name(.git)`
    /// and `git@github.com:owner/name.git`.
    public init?(parsing raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[..<cut])
        }
        for prefix in ["git@github.com:", "https://", "http://", "www.", "github.com/"]
        where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasSuffix(".git") { text.removeLast(4) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let owner = String(parts[0])
        let name = String(parts[1])
        guard RepoRef.isValidOwner(owner), RepoRef.isValidName(name) else { return nil }
        self.init(owner: owner, name: name)
    }

    public var fullName: String { "\(owner)/\(name)" }
    public var description: String { fullName }

    /// GitHub treats owner and name case-insensitively.
    public var key: String { fullName.lowercased() }
    public var ownerKey: String { owner.lowercased() }

    static func isValidOwner(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 39, !value.hasPrefix("-") else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    static func isValidName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 100, value != ".", value != ".." else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
}

public struct Release: Codable, Equatable, Sendable {
    public var tagName: String
    public var url: URL
    public var publishedAt: Date?
    public var isPrerelease: Bool

    public init(tagName: String, url: URL, publishedAt: Date?, isPrerelease: Bool) {
        self.tagName = tagName
        self.url = url
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
    }
}

public struct WorkflowRun: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var name: String?
    public var workflowId: Int
    public var runNumber: Int
    public var status: String?
    public var conclusion: String?
    public var headBranch: String?
    public var event: String?
    public var htmlUrl: URL
    public var createdAt: Date
    public var updatedAt: Date
    public var runStartedAt: Date?
    /// Every failed job ended without a runner or a single step. Read from the run's jobs; GitHub's run JSON
    /// doesn't have it, only the status cache does.
    public var jobsNeverStarted = false

    enum CodingKeys: String, CodingKey {
        case id, name, workflowId, runNumber, status, conclusion, headBranch, event, htmlUrl, createdAt, updatedAt, runStartedAt
        case jobsNeverStarted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        workflowId = try container.decode(Int.self, forKey: .workflowId)
        runNumber = try container.decode(Int.self, forKey: .runNumber)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        conclusion = try container.decodeIfPresent(String.self, forKey: .conclusion)
        headBranch = try container.decodeIfPresent(String.self, forKey: .headBranch)
        event = try container.decodeIfPresent(String.self, forKey: .event)
        htmlUrl = try container.decode(URL.self, forKey: .htmlUrl)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        runStartedAt = try container.decodeIfPresent(Date.self, forKey: .runStartedAt)
        jobsNeverStarted = try container.decodeIfPresent(Bool.self, forKey: .jobsNeverStarted) ?? false
    }

    public init(
        id: Int, name: String?, workflowId: Int, runNumber: Int, status: String?, conclusion: String?,
        headBranch: String?, event: String? = "push", htmlUrl: URL, createdAt: Date, updatedAt: Date,
        runStartedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.workflowId = workflowId
        self.runNumber = runNumber
        self.status = status
        self.conclusion = conclusion
        self.headBranch = headBranch
        self.event = event
        self.htmlUrl = htmlUrl
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.runStartedAt = runStartedAt
    }

    public var isActive: Bool { CIEvaluator.activeStatuses.contains(status ?? "") }
    public var isQueued: Bool { isActive && status != "in_progress" }
    public var isFailure: Bool { CIEvaluator.failedConclusions.contains(conclusion ?? "") && !didNotStart }
    /// The run failed before any of its code ran: an invalid workflow file (`startup_failure`), or jobs GitHub
    /// never handed to a runner, which is how a billing block or a job-level workflow error looks.
    public var didNotStart: Bool {
        conclusion == "startup_failure" || (conclusion == "failure" && jobsNeverStarted)
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Workflow \(workflowId)"
    }
}

/// A job of a workflow run, as far as telling whether it ever started.
public struct WorkflowJob: Equatable, Sendable, Decodable {
    public struct Step: Equatable, Sendable, Decodable {
        public var name: String?
    }

    public var conclusion: String?
    public var runnerId: Int?
    public var runnerName: String?
    public var steps: [Step]?

    public init(conclusion: String?, runnerId: Int? = nil, runnerName: String? = nil, steps: [Step]? = nil) {
        self.conclusion = conclusion
        self.runnerId = runnerId
        self.runnerName = runnerName
        self.steps = steps
    }

    public var neverStarted: Bool {
        (steps ?? []).isEmpty && (runnerId ?? 0) == 0 && (runnerName ?? "").isEmpty
    }
}

public enum CIState: String, Codable, Equatable, Sendable {
    case none, passing, failing, running
    /// Runs are waiting to start (for a runner, an approval or a concurrency slot) and none is in progress.
    case queued
    /// The latest runs failed before any job ran, usually billing or the workflow configuration.
    case notStarted
}

public struct CISummary: Codable, Equatable, Sendable {
    public var state: CIState
    /// In-progress runs on any branch, newest first.
    public var running: [WorkflowRun]
    /// Runs on any branch that are active but not in progress yet, newest first.
    public var queued: [WorkflowRun]
    /// The latest completed run of each workflow on the default branch, newest first.
    public var latestOnDefault: [WorkflowRun]

    public init(state: CIState, running: [WorkflowRun] = [], queued: [WorkflowRun] = [], latestOnDefault: [WorkflowRun] = []) {
        self.state = state
        self.running = running
        self.queued = queued
        self.latestOnDefault = latestOnDefault
    }

    public static let empty = CISummary(state: .none)

    /// The run the status icon links to: the newest running one, else the newest queued one, else the newest
    /// failure, else the newest run that never started, else the newest result.
    public var primaryRun: WorkflowRun? {
        running.first ?? queued.first ?? latestOnDefault.first(where: \.isFailure)
            ?? latestOnDefault.first(where: \.didNotStart) ?? latestOnDefault.first
    }
}

/// Open security alerts of one repository. A count is `nil` when it couldn't be read: alerts need write access
/// (admin for secret scanning), private repositories need GitHub Advanced Security, and the feature may be off.
public struct SecurityAlerts: Codable, Equatable, Sendable {
    /// Code and secret scanning are counted from one page of REST results, so this many means at least this many.
    public static let pageLimit = 100

    public var dependabot: Int?
    public var codeScanning: Int?
    public var secretScanning: Int?

    public init(dependabot: Int? = nil, codeScanning: Int? = nil, secretScanning: Int? = nil) {
        self.dependabot = dependabot
        self.codeScanning = codeScanning
        self.secretScanning = secretScanning
    }

    /// Open alerts of the kinds that could be read.
    public var total: Int { (dependabot ?? 0) + (codeScanning ?? 0) + (secretScanning ?? 0) }
    public var hasAlerts: Bool { total > 0 }
    /// Every kind could be read.
    public var isComplete: Bool { dependabot != nil && codeScanning != nil && secretScanning != nil }
    /// A scanning count stopped at `pageLimit`.
    public var isCapped: Bool { codeScanning == Self.pageLimit || secretScanning == Self.pageLimit }
}

public enum RepoProblem: Codable, Equatable, Sendable {
    /// The token can't see the repo (not installed, private, moved to an owner without access, or deleted).
    case noAccess
    case error(String)
}

/// Everything Shipwatch shows for a single repository.
public struct RepoStatus: Codable, Equatable, Sendable {
    public var ref: RepoRef
    public var url: URL
    public var isPrivate: Bool
    public var isArchived: Bool
    public var defaultBranch: String?
    /// The commit the default branch points at on GitHub.
    public var defaultBranchHead: String?
    public var latestRelease: Release?
    public var openIssues: Int
    public var openPullRequests: Int
    public var dependabotPullRequests: Int
    public var pushedAt: Date?
    public var lastIssueUpdate: Date?
    public var lastPullRequestUpdate: Date?
    /// `nil` when workflow runs could not be read.
    public var ci: CISummary?
    /// `nil` unless security alerts were requested.
    public var securityAlerts: SecurityAlerts?
    public var problem: RepoProblem?

    public init(
        ref: RepoRef, url: URL? = nil, isPrivate: Bool = false, isArchived: Bool = false,
        defaultBranch: String? = nil, defaultBranchHead: String? = nil, latestRelease: Release? = nil, openIssues: Int = 0,
        openPullRequests: Int = 0, dependabotPullRequests: Int = 0, pushedAt: Date? = nil,
        lastIssueUpdate: Date? = nil, lastPullRequestUpdate: Date? = nil, ci: CISummary? = nil,
        securityAlerts: SecurityAlerts? = nil, problem: RepoProblem? = nil
    ) {
        self.ref = ref
        self.url = url ?? GitHubLinks.repo(ref)
        self.isPrivate = isPrivate
        self.isArchived = isArchived
        self.defaultBranch = defaultBranch
        self.defaultBranchHead = defaultBranchHead
        self.latestRelease = latestRelease
        self.openIssues = openIssues
        self.openPullRequests = openPullRequests
        self.dependabotPullRequests = dependabotPullRequests
        self.pushedAt = pushedAt
        self.lastIssueUpdate = lastIssueUpdate
        self.lastPullRequestUpdate = lastPullRequestUpdate
        self.ci = ci
        self.securityAlerts = securityAlerts
        self.problem = problem
    }

    public var ciState: CIState { ci?.state ?? .none }

    public func lastActivity(_ mode: ActivityMode) -> Date? {
        switch mode {
        case .lastPush:
            return pushedAt
        case .anyUpdate:
            return [pushedAt, lastIssueUpdate, lastPullRequestUpdate].compactMap { $0 }.max()
        }
    }
}

public enum ActivityMode: String, Codable, CaseIterable, Sendable {
    case lastPush
    case anyUpdate

    public var label: String {
        switch self {
        case .lastPush: "Last push"
        case .anyUpdate: "Any update"
        }
    }
}

/// A repository the token can read, used by the "Add Repositories" picker.
public struct RepoListing: Equatable, Sendable, Identifiable, Decodable {
    public struct Owner: Equatable, Sendable, Decodable {
        public var login: String
    }

    public var name: String
    public var owner: Owner
    public var `private`: Bool
    public var archived: Bool?
    public var pushedAt: Date?

    public init(owner: String, name: String, isPrivate: Bool, pushedAt: Date?) {
        self.name = name
        self.owner = Owner(login: owner)
        self.private = isPrivate
        self.archived = false
        self.pushedAt = pushedAt
    }

    public var ref: RepoRef { RepoRef(owner: owner.login, name: name) }
    public var id: String { ref.key }
}

public struct GitHubUser: Equatable, Sendable, Decodable {
    public var login: String
    public var name: String?
    public var avatarUrl: URL?

    public init(login: String, name: String? = nil, avatarUrl: URL? = nil) {
        self.login = login
        self.name = name
        self.avatarUrl = avatarUrl
    }
}

public struct AppInstallation: Equatable, Sendable, Identifiable, Decodable {
    public struct Account: Equatable, Sendable, Decodable {
        public var login: String
    }

    public var id: Int
    public var appSlug: String?
    public var account: Account
    public var repositorySelection: String?
    public var permissions: [String: String]?

    public init(id: Int, appSlug: String?, account: String, repositorySelection: String?, permissions: [String: String]?) {
        self.id = id
        self.appSlug = appSlug
        self.account = Account(login: account)
        self.repositorySelection = repositorySelection
        self.permissions = permissions
    }
}

public struct RateLimit: Equatable, Sendable {
    public var remaining: Int
    public var resetAt: Date

    public init(remaining: Int, resetAt: Date) {
        self.remaining = remaining
        self.resetAt = resetAt
    }
}
