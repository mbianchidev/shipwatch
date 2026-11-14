import Foundation

public enum CloneSkipReason: Equatable, Sendable {
    case noLocalBranch
    case uncommittedChanges
    case diverged
    case rebaseInProgress

    public func message(branch: String, remote: String) -> String {
        switch self {
        case .noLocalBranch: "no local \(branch) branch"
        case .uncommittedChanges: "uncommitted changes on \(branch)"
        case .diverged: "\(branch) diverged from \(remote)"
        case .rebaseInProgress: "rebase of \(branch) in progress"
        }
    }
}

public enum CloneSyncOutcome: Equatable, Sendable {
    case upToDate
    case updated(commits: Int)
    case skipped(CloneSkipReason)
    case failed(String)
}

/// Fast-forwards the local default branch of a clone to the remote one. Never creates commits, resets, stashes,
/// forces or switches branches: anything that isn't a clean fast-forward is skipped with a reason.
public struct CloneSyncer: Sendable {
    public static let fetchTimeout: TimeInterval = 120
    /// Keeps background git from starting maintenance in the user's repositories.
    static let quietConfig = ["-c", "gc.auto=0", "-c", "maintenance.auto=false"]
    static let reflogAction = "shipwatch fast-forward"

    private let git: any GitRunning

    public init(git: any GitRunning) {
        self.git = git
    }

    /// `remoteHead` is the default branch head GitHub reported; when the local branch already points there, git never touches the network.
    public func sync(_ clone: LocalClone, branch: String, remoteHead: String) -> CloneSyncOutcome {
        guard Self.isSafeName(branch), Self.isSafeName(clone.remote) else {
            return .failed("unexpected branch or remote name")
        }
        do {
            return try fastForward(clone, branch: branch, remoteHead: remoteHead.lowercased())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.contains { $0.isWhitespace || $0 == ":" || $0.isNewline }
    }

    private func fastForward(_ clone: LocalClone, branch: String, remoteHead: String) throws -> CloneSyncOutcome {
        let directory = clone.path
        let localRef = "refs/heads/\(branch)"
        let trackingRef = "refs/remotes/\(clone.remote)/\(branch)"

        guard let local = try resolve(localRef, in: directory) else { return .skipped(.noLocalBranch) }
        if local == remoteHead { return .upToDate }
        if isBeingRebased(localRef, gitDirectory: directory.appendingPathComponent(".git")) {
            return .skipped(.rebaseInProgress)
        }

        let worktrees = try git.checked(["worktree", "list", "--porcelain"], in: directory)
        let worktree = Self.worktree(checkingOut: localRef, porcelain: worktrees.stdout)
        if let worktree {
            let status = try git.checked(["status", "--porcelain", "--untracked-files=no"], in: worktree)
            if !status.trimmed.isEmpty { return .skipped(.uncommittedChanges) }
        }

        if try resolve(trackingRef, in: directory) != remoteHead {
            try git.checked(
                Self.quietConfig + [
                    "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--recurse-submodules=no",
                    clone.remote, "+\(localRef):\(trackingRef)",
                ],
                in: directory,
                environment: try sshEnvironment(in: directory),
                timeout: Self.fetchTimeout
            )
        }
        guard let target = try resolve(trackingRef, in: directory) else {
            return .failed("\(clone.remote)/\(branch) not found after fetching")
        }
        if target == local { return .upToDate }

        let ancestry = try git.run(["merge-base", "--is-ancestor", local, target], in: directory)
        switch ancestry.status {
        case 0: break
        case 1: return .skipped(.diverged)
        default: throw GitError.commandFailed(ancestry.errorSummary)
        }
        let count = try git.run(["rev-list", "--count", "\(local)..\(target)"], in: directory)
        let commits = count.succeeded ? Int(count.trimmed) ?? 0 : 0

        if let worktree {
            // `--ff-only` refuses on its own if files changed since the status check, so nothing is ever overwritten.
            try git.checked(
                Self.quietConfig + ["merge", "--ff-only", "--quiet", target],
                in: worktree,
                environment: ["GIT_REFLOG_ACTION": Self.reflogAction],
                timeout: Self.fetchTimeout
            )
        } else {
            // Compare-and-swap: fails if the branch moved since `local` was read.
            try git.checked(["update-ref", "-m", "\(Self.reflogAction) to \(clone.remote)/\(branch)", localRef, target, local], in: directory)
        }
        return .updated(commits: commits)
    }

    private func resolve(_ ref: String, in directory: URL) throws -> String? {
        let output = try git.run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: directory)
        guard output.succeeded, !output.trimmed.isEmpty else { return nil }
        return output.trimmed.lowercased()
    }

    /// The worktree that has `ref` checked out, if any. Worktrees whose folder is gone are ignored.
    static func worktree(checkingOut ref: String, porcelain: String, fileManager: FileManager = .default) -> URL? {
        var path: String?
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst(9))
            } else if line == "branch \(ref)", let path, fileManager.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            } else if line.isEmpty {
                path = nil
            }
        }
        return nil
    }

    /// A rebase leaves HEAD detached, so the worktree list doesn't show the branch; its state folder names it instead.
    func isBeingRebased(_ ref: String, gitDirectory: URL, fileManager: FileManager = .default) -> Bool {
        var directories = [gitDirectory]
        if let linked = try? fileManager.contentsOfDirectory(at: gitDirectory.appendingPathComponent("worktrees"), includingPropertiesForKeys: nil) {
            directories += linked
        }
        return directories.contains { directory in
            ["rebase-merge", "rebase-apply"].contains { state in
                let headName = directory.appendingPathComponent(state).appendingPathComponent("head-name")
                let name = (try? String(contentsOf: headName, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                return name == ref
            }
        }
    }

    /// SSH must not wait for a passphrase or host key answer. A repository's own `core.sshCommand` is respected.
    private func sshEnvironment(in directory: URL) throws -> [String: String] {
        let configured = try git.run(["config", "--get", "core.sshCommand"], in: directory)
        if configured.succeeded, !configured.trimmed.isEmpty { return [:] }
        return ["GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o ConnectTimeout=15"]
    }
}
