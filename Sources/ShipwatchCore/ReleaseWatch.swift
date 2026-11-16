import Foundation

/// A GitHub release that became a repository's latest since the previous refresh.
public struct NewRelease: Equatable, Sendable {
    public var ref: RepoRef
    public var release: Release

    public init(ref: RepoRef, release: Release) {
        self.ref = ref
        self.release = release
    }
}

/// Finds the releases to notify about by comparing two refreshes. Only GitHub releases count: a pushed tag without a
/// release never changes `RepoStatus.latestRelease`, and drafts are never listed.
public enum ReleaseWatch {
    /// Leeway for the clock difference between this Mac and GitHub.
    public static let clockTolerance: TimeInterval = 120

    /// Releases of the `watched` repositories (`RepoRef.key`) that are the latest in `current` under another tag than
    /// in `previous`, and were published after `previousAt`, when `previous` was loaded. The publishing time keeps
    /// older releases quiet when they become the latest for another reason: a newer one was deleted, pre-releases
    /// were turned on, or access was granted. Repositories missing from `previous` have nothing to compare yet.
    public static func newReleases(
        previous: [String: RepoStatus],
        previousAt: Date?,
        current: [String: RepoStatus],
        watched: Set<String>
    ) -> [NewRelease] {
        guard let previousAt else { return [] }
        let cutoff = previousAt.addingTimeInterval(-clockTolerance)
        return watched.sorted().compactMap { key in
            guard let before = previous[key], let after = current[key], after.problem == nil,
                  let release = after.latestRelease, release.tagName != before.latestRelease?.tagName,
                  let published = release.publishedAt, published > cutoff
            else { return nil }
            return NewRelease(ref: after.ref, release: release)
        }
    }
}
