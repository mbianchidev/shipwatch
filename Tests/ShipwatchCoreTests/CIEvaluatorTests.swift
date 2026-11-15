import Foundation
import Testing
@testable import ShipwatchCore

struct CIEvaluatorTests {
    typealias F = Fixtures

    @Test func noRunsMeansNone() {
        #expect(CIEvaluator.summarize(runs: [], defaultBranch: "main").state == .none)
    }

    @Test func queuedRunOnAnyBranchMeansQueued() {
        let runs = [
            F.run(3, workflow: 1, status: "queued", conclusion: nil, branch: "dependabot/npm/vite-6.1", created: "2026-11-14T15:39:00Z"),
            F.run(2, workflow: 1, conclusion: "failure", created: "2026-11-14T15:00:00Z"),
        ]
        let summary = CIEvaluator.summarize(runs: runs, defaultBranch: "main")
        #expect(summary.state == .queued)
        #expect(summary.running.isEmpty)
        #expect(summary.queued.map(\.id) == [3])
        #expect(summary.primaryRun?.id == 3)
    }

    @Test(arguments: ["waiting", "requested", "pending"])
    func runsNotYetInProgressAreQueued(_ status: String) {
        let runs = [F.run(1, workflow: 1, status: status, conclusion: nil, created: "2026-11-14T15:00:00Z")]
        #expect(CIEvaluator.summarize(runs: runs, defaultBranch: "main").state == .queued)
    }

    @Test func inProgressRunMeansRunningAndKeepsQueuedApart() {
        let runs = [
            F.run(3, workflow: 2, status: "queued", conclusion: nil, created: "2026-11-14T15:39:00Z"),
            F.run(2, workflow: 1, status: "in_progress", conclusion: nil, created: "2026-11-14T15:30:00Z"),
        ]
        let summary = CIEvaluator.summarize(runs: runs, defaultBranch: "main")
        #expect(summary.state == .running)
        #expect(summary.running.map(\.id) == [2])
        #expect(summary.queued.map(\.id) == [3])
        #expect(summary.primaryRun?.id == 2)
    }

    @Test func onlyLatestRunPerWorkflowOnDefaultBranchCounts() {
        let runs = [
            F.run(5, workflow: 1, conclusion: "success", created: "2026-11-14T15:00:00Z"),
            F.run(4, workflow: 1, conclusion: "failure", created: "2026-11-14T14:00:00Z"),
            F.run(3, workflow: 2, name: "Release", conclusion: "success", created: "2026-11-11T10:00:00Z"),
            F.run(6, workflow: 2, name: "Release", conclusion: "failure", branch: "feature", created: "2026-11-14T15:30:00Z"),
        ]
        let summary = CIEvaluator.summarize(runs: runs, defaultBranch: "main")
        #expect(summary.state == .passing)
        #expect(summary.latestOnDefault.map(\.id) == [5, 3])
    }

    @Test(arguments: ["failure", "timed_out"])
    func failedConclusionsMeanFailing(_ conclusion: String) {
        let runs = [
            F.run(2, workflow: 1, conclusion: conclusion, created: "2026-11-14T15:00:00Z"),
            F.run(1, workflow: 2, conclusion: "success", created: "2026-11-14T14:00:00Z"),
        ]
        let summary = CIEvaluator.summarize(runs: runs, defaultBranch: "main")
        #expect(summary.state == .failing)
        #expect(summary.primaryRun?.id == 2)
    }

    @Test func runsThatNeverStartedAreNotStarted() {
        var blocked = F.run(3, workflow: 1, conclusion: "failure", created: "2026-11-14T15:00:00Z")
        blocked.jobsNeverStarted = true
        let runs = [
            blocked,
            F.run(2, workflow: 2, conclusion: "startup_failure", created: "2026-11-14T14:00:00Z"),
            F.run(1, workflow: 3, conclusion: "success", created: "2026-11-14T13:00:00Z"),
        ]
        let summary = CIEvaluator.summarize(runs: runs, defaultBranch: "main")
        #expect(summary.state == .notStarted)
        #expect(summary.primaryRun?.id == 3)
    }

    @Test func realFailureBeatsNotStarted() {
        let runs = [
            F.run(2, workflow: 1, conclusion: "startup_failure", created: "2026-11-14T15:00:00Z"),
            F.run(1, workflow: 2, conclusion: "failure", created: "2026-11-14T14:00:00Z"),
        ]
        let summary = CIEvaluator.summarize(runs: runs, defaultBranch: "main")
        #expect(summary.state == .failing)
        #expect(summary.primaryRun?.id == 1)
    }

    @Test func jobsNeverStartedOnlyWhenEveryFailedJobLackedARunner() {
        let blocked = WorkflowJob(conclusion: "failure", runnerId: 0, runnerName: "", steps: [])
        let skipped = WorkflowJob(conclusion: "skipped")
        let ran = WorkflowJob(conclusion: "failure", runnerId: 1_000_063_501, runnerName: "GitHub Actions 1000063501", steps: [.init(name: "Set up job")])
        #expect(CIEvaluator.neverStarted([blocked, blocked, skipped]))
        #expect(!CIEvaluator.neverStarted([blocked, ran]))
        #expect(!CIEvaluator.neverStarted([skipped]))
        #expect(!CIEvaluator.neverStarted([]))
    }

    @Test func cancelledAndSkippedAreNotFailures() {
        let runs = [
            F.run(2, workflow: 1, conclusion: "cancelled", created: "2026-11-14T15:00:00Z"),
            F.run(1, workflow: 2, conclusion: "skipped", created: "2026-11-14T14:00:00Z"),
        ]
        #expect(CIEvaluator.summarize(runs: runs, defaultBranch: "main").state == .passing)
    }

    @Test func overallCountsEachCIState() {
        let ref = RepoRef(owner: "mbianchidev", name: "api-server")
        let statuses = [
            RepoStatus(ref: ref, ci: CISummary(state: .running)),
            RepoStatus(ref: ref, ci: CISummary(state: .queued)),
            RepoStatus(ref: ref, ci: CISummary(state: .failing)),
            RepoStatus(ref: ref, ci: CISummary(state: .notStarted)),
            RepoStatus(ref: ref, ci: CISummary(state: .passing)),
            RepoStatus(ref: ref),
        ]
        let overall = OverallStatus(statuses)
        #expect(overall == OverallStatus(running: 1, queued: 1, failing: 1, notStarted: 1, passing: 1))
    }

    @Test func activityModes() {
        let status = RepoStatus(
            ref: RepoRef(owner: "acme-org", name: "infra"),
            pushedAt: Fixtures.date("2026-11-12T10:00:00Z"),
            lastIssueUpdate: Fixtures.date("2026-11-14T09:00:00Z"),
            lastPullRequestUpdate: Fixtures.date("2026-11-13T09:00:00Z")
        )
        #expect(status.lastActivity(.lastPush) == Fixtures.date("2026-11-12T10:00:00Z"))
        #expect(status.lastActivity(.anyUpdate) == Fixtures.date("2026-11-14T09:00:00Z"))
    }
}
