import Foundation

public enum GitHubLinks {
    public static let web = URL(string: "https://github.com")!

    public static func repo(_ ref: RepoRef) -> URL {
        web.appending(path: ref.owner).appending(path: ref.name)
    }

    public static func issues(_ ref: RepoRef) -> URL {
        repo(ref).appending(path: "issues")
    }

    public static func pullRequests(_ ref: RepoRef) -> URL {
        repo(ref).appending(path: "pulls")
    }

    /// Open pull requests authored by Dependabot.
    public static func dependabotPullRequests(_ ref: RepoRef) -> URL {
        var components = URLComponents(url: pullRequests(ref), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: "is:pr is:open author:app/dependabot")]
        return components.url!
    }

    public static func actions(_ ref: RepoRef) -> URL {
        repo(ref).appending(path: "actions")
    }

    public static func releases(_ ref: RepoRef) -> URL {
        repo(ref).appending(path: "releases")
    }

    /// Open issues across several repositories, as a GitHub search.
    public static func issues(_ refs: [RepoRef]) -> URL {
        search("is:issue is:open", in: refs, type: "issues")
    }

    /// Open pull requests across several repositories, as a GitHub search.
    public static func pullRequests(_ refs: [RepoRef]) -> URL {
        search("is:pr is:open", in: refs, type: "pullrequests")
    }

    /// Open Dependabot pull requests across several repositories, as a GitHub search.
    public static func dependabotPullRequests(_ refs: [RepoRef]) -> URL {
        search("is:pr is:open author:app/dependabot", in: refs, type: "pullrequests")
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
