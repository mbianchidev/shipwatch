import Foundation

public enum GitHubLinks {
    public static let web = URL(string: "https://github.com")!

    public static func repo(_ ref: RepoRef) -> URL {
        web.appending(path: ref.owner).appending(path: ref.name)
    }

    /// Open issues, only those assigned to `assignee` when set.
    public static func issues(_ ref: RepoRef, assignee: String? = nil) -> URL {
        let url = repo(ref).appending(path: "issues")
        guard let assignee else { return url }
        return filtered(url, "q", "is:issue is:open assignee:\(assignee)")
    }

    /// Open pull requests, only those assigned to `assignee` when set.
    public static func pullRequests(_ ref: RepoRef, assignee: String? = nil) -> URL {
        let url = repo(ref).appending(path: "pulls")
        guard let assignee else { return url }
        return filtered(url, "q", "is:pr is:open assignee:\(assignee)")
    }

    /// Open pull requests authored by Dependabot, only those assigned to `assignee` when set. GitHub redirects a lone
    /// `author:` filter to `/pulls/app%2Fdependabot`, which its pull request list doesn't filter by; spelling out its
    /// default sort keeps the query.
    public static func dependabotPullRequests(_ ref: RepoRef, assignee: String? = nil) -> URL {
        filtered(
            repo(ref).appending(path: "pulls"), "q",
            "is:pr is:open author:app/dependabot" + qualifier("assignee", assignee) + " sort:created-desc"
        )
    }

    /// Open pull requests waiting for `reviewer`'s review, only those still needing an approval when asked.
    public static func reviewRequests(_ ref: RepoRef, reviewer: String, needingApproval: Bool) -> URL {
        filtered(repo(ref).appending(path: "pulls"), "q", reviewQualifiers(reviewer, needingApproval))
    }

    /// Workflow runs, only those `actor` triggered when set.
    public static func actions(_ ref: RepoRef, actor: String? = nil) -> URL {
        let url = repo(ref).appending(path: "actions")
        guard let actor else { return url }
        return filtered(url, "query", "actor:\(actor)")
    }

    private static func filtered(_ url: URL, _ name: String, _ value: String) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: name, value: value)]
        return components.url!
    }

    private static func reviewQualifiers(_ reviewer: String, _ needingApproval: Bool) -> String {
        "is:pr is:open review-requested:\(reviewer)" + (needingApproval ? " review:required" : "")
    }

    private static func qualifier(_ name: String, _ value: String?) -> String {
        value.map { " \(name):\($0)" } ?? ""
    }

    public static func releases(_ ref: RepoRef) -> URL {
        repo(ref).appending(path: "releases")
    }

    /// The Security tab, with Dependabot, code scanning and secret scanning alerts.
    public static func security(_ ref: RepoRef) -> URL {
        repo(ref).appending(path: "security")
    }

    /// Open issues across several repositories, as a GitHub search.
    public static func issues(_ refs: [RepoRef], assignee: String? = nil) -> URL {
        search("is:issue is:open" + qualifier("assignee", assignee), in: refs, type: "issues")
    }

    /// Open pull requests across several repositories, as a GitHub search.
    public static func pullRequests(_ refs: [RepoRef], assignee: String? = nil) -> URL {
        search("is:pr is:open" + qualifier("assignee", assignee), in: refs, type: "pullrequests")
    }

    /// Open Dependabot pull requests across several repositories, as a GitHub search.
    public static func dependabotPullRequests(_ refs: [RepoRef], assignee: String? = nil) -> URL {
        search("is:pr is:open author:app/dependabot" + qualifier("assignee", assignee), in: refs, type: "pullrequests")
    }

    /// Open pull requests waiting for `reviewer`'s review across several repositories, as a GitHub search.
    public static func reviewRequests(_ refs: [RepoRef], reviewer: String, needingApproval: Bool) -> URL {
        search(reviewQualifiers(reviewer, needingApproval), in: refs, type: "pullrequests")
    }

    private static func search(_ qualifiers: String, in refs: [RepoRef], type: String) -> URL {
        var components = URLComponents(url: web.appending(path: "search"), resolvingAgainstBaseURL: false)!
        let repos = refs.map { "repo:\($0.fullName)" }.joined(separator: " ")
        components.queryItems = [URLQueryItem(name: "q", value: "\(qualifiers) \(repos)"), URLQueryItem(name: "type", value: type)]
        return components.url!
    }

    public static func appInstall(slug: String) -> URL {
        web.appending(path: "apps").appending(path: slug).appending(path: "installations").appending(path: "new")
    }

    public static let deviceLogin = URL(string: "https://github.com/login/device")!
}
