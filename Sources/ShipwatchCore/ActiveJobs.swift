import Foundation

/// The kind of machine a job runs on, read from its `runs-on` labels.
public enum RunnerKind: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
    case macOS, linux, windows, selfHosted, other

    /// Self-hosted runners don't count toward GitHub's limits, so `self-hosted` wins over an OS label. GitHub-hosted
    /// images start with `macos`, `ubuntu` or `windows`, larger runners included; larger runners picked by a custom
    /// label or a runner group can't be told apart and are `other`.
    public init(labels: [String]) {
        let labels = labels.map { $0.lowercased() }
        func has(_ prefix: String) -> Bool { labels.contains { $0.hasPrefix(prefix) } }
        if labels.contains("self-hosted") {
            self = .selfHosted
        } else if has("macos") {
            self = .macOS
        } else if has("ubuntu") {
            self = .linux
        } else if has("windows") {
            self = .windows
        } else {
            self = .other
        }
    }

    public var label: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        case .windows: "Windows"
        case .selfHosted: "Self-hosted"
        case .other: "Other"
        }
    }
}

public struct JobTally: Codable, Equatable, Sendable {
    public var running: Int
    /// Waiting for a runner.
    public var queued: Int

    public init(running: Int = 0, queued: Int = 0) {
        self.running = running
        self.queued = queued
    }

    public var isEmpty: Bool { running == 0 && queued == 0 }
}

/// The running and queued jobs of a repository's active workflow runs, per kind of runner.
public struct ActiveJobs: Codable, Equatable, Sendable {
    public var tallies: [RunnerKind: JobTally]

    public init(tallies: [RunnerKind: JobTally] = [:]) {
        self.tallies = tallies
    }

    /// Jobs waiting for an approval or already done don't count.
    public init(jobs: [WorkflowJob]) {
        self.init()
        for job in jobs {
            let kind = RunnerKind(labels: job.labels ?? [])
            switch job.status {
            case "in_progress": tallies[kind, default: JobTally()].running += 1
            case "queued": tallies[kind, default: JobTally()].queued += 1
            default: continue
            }
        }
    }

    public subscript(kind: RunnerKind) -> JobTally { tallies[kind] ?? JobTally() }

    public var isEmpty: Bool { tallies.values.allSatisfy(\.isEmpty) }

    public mutating func add(_ other: ActiveJobs) {
        for (kind, tally) in other.tallies {
            tallies[kind, default: JobTally()].running += tally.running
            tallies[kind, default: JobTally()].queued += tally.queued
        }
    }
}

/// The active jobs in the tracked repositories of one organization or user. GitHub counts concurrency per account,
/// so jobs in repositories Shipwatch doesn't track aren't included and the real numbers can be higher.
public struct OwnerJobs: Equatable, Sendable, Identifiable {
    /// Concurrent macOS jobs per account on GitHub's Free, Pro and Team plans, shared by standard and larger
    /// runners. Enterprise allows 50, but the plan is only visible to owners.
    public static let macOSLimit = 5

    /// As the first of its repositories spells it.
    public var login: String
    public var jobs: ActiveJobs
    /// Repositories with active runs whose jobs weren't read.
    public var unread: Int

    public init(login: String, jobs: ActiveJobs = ActiveJobs(), unread: Int = 0) {
        self.login = login
        self.jobs = jobs
        self.unread = unread
    }

    /// Matches `RepoRef.ownerKey`.
    public var id: String { login.lowercased() }

    /// Owners with active jobs or unread repositories, sorted by login.
    public static func group(_ statuses: [RepoStatus]) -> [OwnerJobs] {
        var owners: [String: OwnerJobs] = [:]
        for status in statuses where status.problem == nil {
            guard let ci = status.ci else { continue }
            let key = status.ref.ownerKey
            if let jobs = ci.activeJobs {
                owners[key, default: OwnerJobs(login: status.ref.owner)].jobs.add(jobs)
            } else if !ci.running.isEmpty || !ci.queued.isEmpty {
                owners[key, default: OwnerJobs(login: status.ref.owner)].unread += 1
            }
        }
        return owners.values
            .filter { !$0.jobs.isEmpty || $0.unread > 0 }
            .sorted { $0.login.localizedStandardCompare($1.login) == .orderedAscending }
    }
}
