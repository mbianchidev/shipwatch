import Foundation

public enum CIEvaluator {
    public static let activeStatuses: Set<String> = ["queued", "in_progress", "waiting", "requested", "pending"]
    public static let failedConclusions: Set<String> = ["failure", "timed_out", "startup_failure"]

    /// Running wins over failing, failing over passing. Only the latest completed run of each workflow
    /// on the default branch decides failing vs passing, so an old red run that was fixed later is ignored.
    public static func summarize(runs: [WorkflowRun], defaultBranch: String?) -> CISummary {
        let sorted = runs.sorted { $0.createdAt > $1.createdAt }
        let running = sorted.filter(\.isActive)

        var seenWorkflows = Set<Int>()
        var latest: [WorkflowRun] = []
        for run in sorted where !run.isActive && run.status == "completed" {
            if let defaultBranch, let branch = run.headBranch, branch != defaultBranch { continue }
            if seenWorkflows.insert(run.workflowId).inserted {
                latest.append(run)
            }
        }

        let state: CIState
        if !running.isEmpty {
            state = .running
        } else if latest.contains(where: \.isFailure) {
            state = .failing
        } else if !latest.isEmpty {
            state = .passing
        } else {
            state = .none
        }
        return CISummary(state: state, running: running, latestOnDefault: latest)
    }
}

/// What the menu bar icon shows across all visible repositories.
public struct OverallStatus: Equatable, Sendable {
    public var running: Int
    public var failing: Int
    public var passing: Int

    public init(running: Int = 0, failing: Int = 0, passing: Int = 0) {
        self.running = running
        self.failing = failing
        self.passing = passing
    }

    public init(_ statuses: [RepoStatus]) {
        self.init()
        for status in statuses {
            switch status.ciState {
            case .running: running += 1
            case .failing: failing += 1
            case .passing: passing += 1
            case .none: break
            }
        }
    }

    /// Red beats yellow: a failure needs attention, a running workflow only needs patience.
    public var indicator: CIState {
        if failing > 0 { return .failing }
        if running > 0 { return .running }
        return .passing
    }
}
