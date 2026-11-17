import Foundation
import Testing
@testable import ShipwatchCore

@Suite struct ActiveJobsTests {
    @Test(arguments: [
        (["macos-latest"], RunnerKind.macOS),
        (["macos-15-xlarge"], .macOS),
        (["ubuntu-24.04-arm"], .linux),
        (["windows-latest"], .windows),
        (["self-hosted", "macOS", "ARM64"], .selfHosted),
        (["linux-8core-gpu"], .other),
        ([], .other),
    ])
    func classifiesRunnerLabels(_ labels: [String], _ expected: RunnerKind) {
        #expect(RunnerKind(labels: labels) == expected)
    }

    @Test func countsRunningAndQueuedJobsOnly() {
        let jobs = ActiveJobs(jobs: [
            WorkflowJob(status: "in_progress", conclusion: nil, labels: ["macos-15"]),
            WorkflowJob(status: "in_progress", conclusion: nil, labels: ["macos-latest"]),
            WorkflowJob(status: "queued", conclusion: nil, labels: ["macos-latest"]),
            WorkflowJob(status: "in_progress", conclusion: nil, labels: ["ubuntu-latest"]),
            WorkflowJob(status: "waiting", conclusion: nil, labels: ["ubuntu-latest"]),
            WorkflowJob(status: "completed", conclusion: "success", labels: ["windows-latest"]),
        ])
        #expect(jobs == ActiveJobs(tallies: [.macOS: JobTally(running: 2, queued: 1), .linux: JobTally(running: 1)]))
        #expect(jobs[.windows].isEmpty)
    }

    @Test func groupsByOwnerAndCountsUnreadRepos() {
        let run = Fixtures.run(1, workflow: 1, status: "in_progress", conclusion: nil, created: "2026-11-14T15:00:00Z")
        func status(_ name: String, active: Bool = true, jobs: ActiveJobs?) -> RepoStatus {
            RepoStatus(
                ref: RepoRef(parsing: name)!,
                ci: CISummary(state: active ? .running : .passing, running: active ? [run] : [], activeJobs: jobs)
            )
        }
        let mac = ActiveJobs(tallies: [.macOS: JobTally(running: 3)])
        let owners = OwnerJobs.group([
            status("octocat/api-server", jobs: mac),
            status("Octocat/website", jobs: ActiveJobs(tallies: [.macOS: JobTally(running: 2, queued: 1)])),
            status("acme-org/infra", jobs: nil),
            status("acme-org/handbook", active: false, jobs: nil),
            status("mona/idle", jobs: ActiveJobs()),
            RepoStatus(ref: RepoRef(owner: "mona", name: "gone"), problem: .noAccess),
        ])
        #expect(owners == [
            OwnerJobs(login: "acme-org", unread: 1),
            OwnerJobs(login: "octocat", jobs: ActiveJobs(tallies: [.macOS: JobTally(running: 5, queued: 1)])),
        ])
    }
}
