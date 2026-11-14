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

    /// Open pull requests not authored by Dependabot.
    public static func humanPullRequests(_ ref: RepoRef) -> URL {
        var components = URLComponents(url: pullRequests(ref), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: "is:pr is:open -author:app/dependabot")]
        return components.url!
    }

    public static func actions(_ ref: RepoRef) -> URL {
        repo(ref).appending(path: "actions")
    }

    public static func releases(_ ref: RepoRef) -> URL {
        repo(ref).appending(path: "releases")
    }

    public static func appInstall(slug: String) -> URL {
        web.appending(path: "apps").appending(path: slug).appending(path: "installations").appending(path: "new")
    }

    public static let deviceLogin = URL(string: "https://github.com/login/device")!
}
