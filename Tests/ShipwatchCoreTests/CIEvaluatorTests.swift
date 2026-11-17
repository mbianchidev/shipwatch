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

    @Test func pullRequestFailureBeatsRunningAndQueued() {
        let branch = "dependabot/npm_and_yarn/vite-6.1"
        let runs = [
            F.run(3, workflow: 1, status: "in_progress", conclusion: nil, branch: branch, created: "2026-11-14T15:10:00Z"),
            F.run(2, workflow: 2, status: "queued", conclusion: nil, branch: branch, created: "2026-11-14T15:05:00Z"),
            F.run(1, workflow: 3, conclusion: "failure", branch: branch, created: "2026-11-14T15:00:00Z"),
        ]
        #expect(CIEvaluator.pullRequestState(runs: runs) == .failing)
        #expect(CIEvaluator.pullRequestState(runs: Array(runs.prefix(2))) == .running)
        #expect(CIEvaluator.pullRequestState(runs: [runs[1]]) == .queued)
        #expect(CIEvaluator.pullRequestState(runs: []) == .none)
    }

    @Test(arguments: ["cancelled", "timed_out", "startup_failure", "action_required"])
    func pullRequestFailsOnAnythingButSuccessSkippedOrNeutral(_ conclusion: String) {
        let passed = ["success", "skipped", "neutral"].enumerated().map { index, conclusion in
            F.run(index + 1, workflow: index + 1, conclusion: conclusion, created: "2026-11-14T15:00:00Z")
        }
        #expect(CIEvaluator.pullRequestState(runs: passed) == .passing)
        let failed = F.run(9, workflow: 9, conclusion: conclusion, created: "2026-11-14T15:00:00Z")
        #expect(CIEvaluator.pullRequestState(runs: passed + [failed]) == .failing)
    }

    @Test func pullRequestCountsTheLatestRunPerWorkflowAndEvent() {
        let rerun = [
            F.run(2, workflow: 1, conclusion: "success", event: "pull_request", created: "2026-11-14T15:10:00Z"),
            F.run(1, workflow: 1, conclusion: "failure", event: "pull_request", created: "2026-11-14T15:00:00Z"),
        ]
        #expect(CIEvaluator.pullRequestState(runs: rerun) == .passing)
        let push = F.run(3, workflow: 1, conclusion: "failure", event: "push", created: "2026-11-14T14:50:00Z")
        #expect(CIEvaluator.pullRequestState(runs: rerun + [push]) == .failing)
    }

    @Test func dependabotChecksAddUpPullRequestsAcrossRepos() throws {
        func pull(_ number: Int, _ checks: CIState?) -> DependabotPullRequest {
            DependabotPullRequest(
                number: number, url: URL(string: "https://github.com/acme-org/infra/pull/\(number)")!,
                headSha: "\(number)", checks: checks
            )
        }
        let ref = RepoRef(owner: "acme-org", name: "infra")
        let infra = RepoStatus(
            ref: ref, dependabotPullRequests: 25,
            dependabotPulls: [pull(1, .failing), pull(2, .running), pull(3, .passing), pull(4, CIState.none), pull(5, nil)]
        )
        let payments = RepoStatus(ref: ref, dependabotPullRequests: 2, dependabotPulls: [pull(6, .queued), pull(7, .passing)])
        let unread = RepoStatus(ref: ref, dependabotPullRequests: 3, dependabotPulls: [pull(8, nil)])

        let checks = try #require(DependabotChecks([infra, payments, unread]))
        #expect(checks == DependabotChecks(passing: 2, failing: 1, running: 1, queued: 1, noRuns: 1, unchecked: 24))
        #expect(checks.state == .failing)
        #expect(DependabotChecks([payments])?.state == .queued)
        #expect(DependabotChecks([unread]) == nil)
        #expect(DependabotChecks([RepoStatus(ref: ref, dependabotPullRequests: 1)]) == nil)
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
