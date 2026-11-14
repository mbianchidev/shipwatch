import Foundation
import Testing
@testable import ShipwatchCore

@Suite struct RemoteURLTests {
    @Test(arguments: [
        "git@github.com:acme-org/infra.git",
        "git@github.com:acme-org/infra",
        "git@github.com:/acme-org/infra.git",
        "https://github.com/acme-org/infra.git",
        "https://github.com/acme-org/infra/",
        "https://token@github.com/acme-org/infra.git",
        "ssh://git@github.com/acme-org/infra.git",
        "ssh://git@ssh.github.com:443/acme-org/infra.git",
        "git://github.com/acme-org/infra.git",
        "  HTTPS://GitHub.com/acme-org/infra.git\n",
    ])
    func parsesGitHubRemotes(_ url: String) {
        #expect(RepoRef(gitRemote: url) == RepoRef(owner: "acme-org", name: "infra"))
    }

    @Test(arguments: [
        "acme-org/infra",
        "/Users/test/Developer/acme-org/infra",
        "../infra.git",
        "file:///tmp/acme-org/infra.git",
        "git@gitlab.com:acme-org/infra.git",
        "https://github.com.evil.example/acme-org/infra.git",
        "https://github.com/acme-org/infra/tree/main",
        "git@github.com:acme-org",
    ])
    func rejectsOtherRemotes(_ url: String) {
        #expect(RepoRef(gitRemote: url) == nil)
    }

    @Test func readsRemotesFromConfig() {
        let config = """
        [core]
        \trepositoryformatversion = 0
        [remote "origin"]
        \turl = git@github.com:mbianchidev/website.git
        \tURL = git@github.com:ignored/second.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [branch "main"]
        \tremote = origin
        ; a comment
        [remote "upstream"]
        \turl = "https://github.com/acme-org/website.git" ; trailing comment
        [remote.legacy]
        \turl = https://github.com/acme-org/legacy.git # note
        [remote "-x"]
        \turl = https://github.com/acme-org/evil.git
        """
        #expect(GitConfig.remotes(in: config) == [
            .init(name: "origin", url: "git@github.com:mbianchidev/website.git"),
            .init(name: "upstream", url: "https://github.com/acme-org/website.git"),
            .init(name: "legacy", url: "https://github.com/acme-org/legacy.git"),
        ])
    }

    @Test func readsBranchFromHead() {
        #expect(GitConfig.branch(fromHead: "ref: refs/heads/feat/nav\n") == "feat/nav")
        #expect(GitConfig.branch(fromHead: "9f1c2e7a4b3d5e6f708192a3b4c5d6e7f8091a2b\n") == nil)
    }
}

@Suite struct WorkspaceScannerTests {
    let tracked: Set<String> = ["mbianchidev/api-server", "mbianchidev/website", "acme-org/infra"]

    @Test func findsTrackedClonesAndHonorsSkipRules() throws {
        let root = try TempDirectory()
        defer { root.remove() }
        try root.fakeClone("api-server", remotes: ["origin": "git@github.com:mbianchidev/api-server.git"])
        try root.fakeClone("api-server/vendor/nested", remotes: ["origin": "git@github.com:acme-org/infra.git"])
        try root.fakeClone("web/website", remotes: ["origin": "https://github.com/mbianchidev/website"], head: "feat/nav")
        try root.fakeClone("acme/team/infra", remotes: ["origin": "git@github.com:acme-org/infra.git"])
        try root.fakeClone("acme/team/deeper/infra", remotes: ["origin": "git@github.com:acme-org/infra.git"])
        try root.fakeClone("forks/website", remotes: [
            "origin": "git@github.com:someone/website.git", "upstream": "git@github.com:mbianchidev/website.git",
        ])
        try root.fakeClone("archive/old-infra", remotes: ["origin": "git@github.com:acme-org/infra.git"])
        try root.fakeClone(".hidden/infra", remotes: ["origin": "git@github.com:acme-org/infra.git"])
        try root.fakeClone("node_modules/infra", remotes: ["origin": "git@github.com:acme-org/infra.git"])
        try root.fakeClone("other", remotes: ["origin": "git@github.com:acme-org/untracked.git"])
        try root.fakeClone("elsewhere", remotes: ["origin": "git@gitlab.example:acme-org/infra.git"])
        try root.write("linked-worktree/.git", "gitdir: /elsewhere/.git/worktrees/x\n")
        try FileManager.default.createSymbolicLink(at: root.url("alias"), withDestinationURL: root.url("api-server"))

        let scanner = WorkspaceScanner(root: root.base, excluded: [root.url("archive")])
        let scan = scanner.scan(tracked: tracked)

        let found = scan.clones.map { ($0.path.path.replacingOccurrences(of: root.canonical.path + "/", with: ""), $0.ref.key, $0.remote) }
        #expect(found.map(\.0) == ["acme/team/infra", "api-server", "forks/website", "web/website"])
        #expect(found.map(\.1) == ["acme-org/infra", "mbianchidev/api-server", "mbianchidev/website", "mbianchidev/website"])
        #expect(found.map(\.2) == ["origin", "origin", "upstream", "origin"])
        #expect(scan.clones.first { $0.ref.name == "website" && $0.remote == "origin" }?.headBranch == "feat/nav")
        #expect(scan.untracked.map(\.ref.key) == ["acme-org/untracked"])
        #expect(scan.unreadable.isEmpty)
    }

    @Test func rootItselfCanBeAClone() throws {
        let root = try TempDirectory()
        defer { root.remove() }
        try root.fakeClone(".", remotes: ["origin": "git@github.com:acme-org/infra.git"])
        #expect(WorkspaceScanner(root: root.base).scan(tracked: tracked).clones.count == 1)
    }

    @Test func exclusionMatchesWholeFolderNames() {
        #expect(WorkspaceScanner.isExcluded("/w/forks", by: ["/w/forks"]))
        #expect(WorkspaceScanner.isExcluded("/w/forks/a", by: ["/w/forks"]))
        #expect(!WorkspaceScanner.isExcluded("/w/forks-old", by: ["/w/forks"]))
    }
}

@Suite(.enabled(if: ProcessGit.locate() != nil, "git is not installed"))
struct CloneSyncerTests {
    @Test func fastForwardsCheckedOutBranch() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let head = try fixture.pushUpstream(commits: 3)
        try fixture.local.write("notes.txt", "untracked files never block a sync\n")

        #expect(fixture.sync(remoteHead: head) == .updated(commits: 3))
        #expect(try fixture.rev("refs/heads/main") == head)
        #expect(FileManager.default.fileExists(atPath: fixture.local.url("file-3.txt").path))
        let reflog = try fixture.git(["reflog", "-1", "--format=%gs", "main"]).trimmed
        #expect(reflog.hasPrefix(CloneSyncer.reflogAction))
    }

    @Test func updatesBranchThatIsNotCheckedOut() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.git(["switch", "--quiet", "-c", "feat/nav"])
        let head = try fixture.pushUpstream(commits: 2)

        #expect(fixture.sync(remoteHead: head) == .updated(commits: 2))
        #expect(try fixture.rev("refs/heads/main") == head)
        #expect(try fixture.git(["branch", "--show-current"]).trimmed == "feat/nav")
        #expect(!FileManager.default.fileExists(atPath: fixture.local.url("file-1.txt").path))
    }

    @Test func fastForwardsInLinkedWorktree() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.git(["switch", "--quiet", "-c", "feat/nav"])
        let worktree = fixture.root.url("main-worktree")
        try fixture.git(["worktree", "add", "--quiet", worktree.path, "main"])
        let head = try fixture.pushUpstream(commits: 1)

        #expect(fixture.sync(remoteHead: head) == .updated(commits: 1))
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("file-1.txt").path))
    }

    @Test func skipsUncommittedChangesWithoutFetching() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.local.write("README.md", "edited locally\n")
        let before = try fixture.rev("refs/heads/main")
        let head = try fixture.pushUpstream(commits: 1)

        #expect(fixture.sync(remoteHead: head) == .skipped(.uncommittedChanges))
        #expect(try fixture.rev("refs/heads/main") == before)
        #expect(try fixture.rev("refs/remotes/origin/main") == before)
        #expect(try String(contentsOf: fixture.local.url("README.md"), encoding: .utf8) == "edited locally\n")
    }

    @Test func skipsDivergedHistory() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.commit(in: fixture.local, file: "local.txt")
        let before = try fixture.rev("refs/heads/main")
        let head = try fixture.pushUpstream(commits: 1)

        #expect(fixture.sync(remoteHead: head) == .skipped(.diverged))
        #expect(try fixture.rev("refs/heads/main") == before)
    }

    @Test func upToDateWithoutTouchingTheNetwork() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let head = try fixture.rev("refs/heads/main")
        try FileManager.default.removeItem(at: fixture.remote)
        #expect(fixture.sync(remoteHead: head.uppercased()) == .upToDate)
    }

    @Test func missingBranchAndRebaseAreSkipped() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let head = try fixture.pushUpstream(commits: 1)
        #expect(fixture.sync(branch: "trunk", remoteHead: head) == .skipped(.noLocalBranch))

        try fixture.local.write(".git/rebase-merge/head-name", "refs/heads/main\n")
        #expect(fixture.sync(remoteHead: head) == .skipped(.rebaseInProgress))
    }

    @Test func fetchFailureIsReported() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.remote)
        guard case .failed(let message) = fixture.sync(remoteHead: String(repeating: "a", count: 40)) else {
            Issue.record("expected a failure")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func rejectsOptionLikeNames() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        #expect(fixture.sync(branch: "--upload-pack=x", remoteHead: "abc") == .failed("unexpected branch or remote name"))
    }
}

// MARK: - Helpers

struct TempDirectory {
    let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("shipwatch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    var canonical: URL { WorkspaceScanner.canonical(base) }

    func url(_ path: String) -> URL { base.appendingPathComponent(path) }

    func write(_ path: String, _ text: String) throws {
        let file = url(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// A `.git` folder with just a config and HEAD: enough for the scanner, which never runs git.
    func fakeClone(_ path: String, remotes: [String: String], head: String = "main") throws {
        let sections = remotes.sorted { $0.key < $1.key }.map { "[remote \"\($0.key)\"]\n\turl = \($0.value)\n" }
        try write("\(path)/.git/config", "[core]\n\tbare = false\n" + sections.joined())
        try write("\(path)/.git/HEAD", "ref: refs/heads/\(head)\n")
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

/// Keeps the developer's own git config (signing, hooks, aliases) out of the tests.
struct IsolatedGit: GitRunning {
    let git: ProcessGit
    static let environment = [
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
    ]

    func run(_ arguments: [String], in directory: URL, environment: [String: String], timeout: TimeInterval) throws -> GitOutput {
        try git.run(arguments, in: directory, environment: Self.environment.merging(environment) { $1 }, timeout: timeout)
    }
}

/// A bare "GitHub" remote, the clone under test (`local`) and a second clone that pushes new commits.
struct GitFixture {
    let root: TempDirectory
    let remote: URL
    let local: TempDirectory
    let upstream: URL
    let runner = IsolatedGit(git: ProcessGit.locate()!)
    private let counter = Counter()

    init() throws {
        root = try TempDirectory()
        remote = root.url("remote.git")
        upstream = root.url("upstream")
        try runner.checked(["init", "--quiet", "--bare", "-b", "main", remote.path], in: root.base)
        try runner.checked(["clone", "--quiet", remote.path, upstream.path], in: root.base)
        try "# Fixture\n".write(to: upstream.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runner.checked(["add", "."], in: upstream)
        try runner.checked(["commit", "--quiet", "-m", "Initial commit"], in: upstream)
        try runner.checked(["push", "--quiet", "origin", "main"], in: upstream)
        let localPath = root.url("local")
        try runner.checked(["clone", "--quiet", remote.path, localPath.path], in: root.base)
        local = TempDirectory(existing: localPath)
    }

    var clone: LocalClone {
        LocalClone(path: local.base, ref: RepoRef(owner: "acme-org", name: "infra"), remote: "origin", headBranch: "main")
    }

    func sync(branch: String = "main", remoteHead: String) -> CloneSyncOutcome {
        CloneSyncer(git: runner).sync(clone, branch: branch, remoteHead: remoteHead)
    }

    @discardableResult
    func git(_ arguments: [String]) throws -> GitOutput {
        try runner.checked(arguments, in: local.base)
    }

    func rev(_ ref: String) throws -> String {
        try runner.checked(["rev-parse", ref], in: local.base).trimmed
    }

    func commit(in directory: TempDirectory, file: String) throws {
        try directory.write(file, "\(file)\n")
        try runner.checked(["add", file], in: directory.base)
        try runner.checked(["commit", "--quiet", "-m", "Add \(file)"], in: directory.base)
    }

    /// Pushes `commits` new commits to the remote from the other clone and returns the new head.
    func pushUpstream(commits: Int) throws -> String {
        let other = TempDirectory(existing: upstream)
        for _ in 0..<commits {
            try commit(in: other, file: "file-\(counter.next()).txt")
        }
        try runner.checked(["push", "--quiet", "origin", "main"], in: upstream)
        return try runner.checked(["rev-parse", "HEAD"], in: upstream).trimmed
    }

    func remove() {
        root.remove()
    }
}

private final class Counter: @unchecked Sendable {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

extension TempDirectory {
    init(existing: URL) {
        base = existing
    }
}
