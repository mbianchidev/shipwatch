import Foundation
@testable import ShipwatchCore

/// Replays canned responses and records requests. Handlers run in order of arrival.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers, body: Data(text.utf8))
        }
    }

    private let lock = NSLock()
    private let handler: @Sendable (URLRequest) throws -> Reply
    private var recorded: [URLRequest] = []

    init(_ handler: @escaping @Sendable (URLRequest) throws -> Reply) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let reply = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }
}

/// A thread-safe queue of replies for sequential flows like device-flow polling.
final class ReplyQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [MockTransport.Reply]

    init(_ replies: [MockTransport.Reply]) {
        self.replies = replies
    }

    func next() -> MockTransport.Reply {
        lock.withLock { replies.isEmpty ? .json("{}", status: 500) : replies.removeFirst() }
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

extension URLRequest {
    var bodyString: String { httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }

    var formFields: [String: String] {
        var fields: [String: String] = [:]
        for pair in bodyString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return fields
    }
}

enum Fixtures {
    static let now = ISO8601DateFormatter().date(from: "2026-11-14T15:40:00Z")!

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    static func run(
        _ id: Int, workflow: Int, name: String = "CI", status: String = "completed", conclusion: String? = "success",
        branch: String = "main", created: String
    ) -> WorkflowRun {
        WorkflowRun(
            id: id, name: name, workflowId: workflow, runNumber: id, status: status, conclusion: conclusion,
            headBranch: branch, htmlUrl: URL(string: "https://github.com/mbianchidev/api-server/actions/runs/\(id)")!,
            createdAt: date(created), updatedAt: date(created)
        )
    }

    static func repoNode(
        _ fullName: String, releaseTag: String? = "v2.4.1", prerelease: String? = nil, issues: Int = 4, prs: Int = 11,
        isPrivate: Bool = false
    ) -> String {
        let latest = releaseTag.map {
            #"{"tagName":"\#($0)","url":"https://github.com/\#(fullName)/releases/tag/\#($0)","publishedAt":"2026-11-11T10:00:00Z","isPrerelease":false}"#
        } ?? "null"
        var nodes: [String] = []
        if let prerelease {
            nodes.append(#"{"tagName":"\#(prerelease)","url":"https://github.com/\#(fullName)/releases/tag/\#(prerelease)","publishedAt":"2026-11-13T10:00:00Z","isPrerelease":true,"isDraft":false}"#)
        }
        if let releaseTag {
            nodes.append(#"{"tagName":"\#(releaseTag)","url":"https://github.com/\#(fullName)/releases/tag/\#(releaseTag)","publishedAt":"2026-11-11T10:00:00Z","isPrerelease":false,"isDraft":false}"#)
        }
        return """
        {"nameWithOwner":"\(fullName)","url":"https://github.com/\(fullName)","isPrivate":\(isPrivate),"isArchived":false,
         "pushedAt":"2026-11-14T15:36:00Z","defaultBranchRef":{"name":"main","target":{"oid":"9f1c2e7a4b3d5e6f708192a3b4c5d6e7f8091a2b"}},"latestRelease":\(latest),
         "releases":{"nodes":[\(nodes.joined(separator: ","))]},"issues":{"totalCount":\(issues)},
         "pullRequests":{"totalCount":\(prs)},"recentIssue":{"nodes":[{"updatedAt":"2026-11-14T12:00:00Z"}]},
         "recentPullRequest":{"nodes":[{"updatedAt":"2026-11-14T15:39:00Z"}]}}
        """
    }

    static func runsJSON(_ runs: [(id: Int, workflow: Int, status: String, conclusion: String?, branch: String, created: String)]) -> String {
        let items = runs.map { run in
            let conclusion = run.conclusion.map { "\"\($0)\"" } ?? "null"
            return """
            {"id":\(run.id),"name":"CI","workflow_id":\(run.workflow),"run_number":\(run.id),"status":"\(run.status)",
             "conclusion":\(conclusion),"head_branch":"\(run.branch)","event":"push",
             "html_url":"https://github.com/mbianchidev/api-server/actions/runs/\(run.id)",
             "created_at":"\(run.created)","updated_at":"\(run.created)","run_started_at":"\(run.created)"}
            """
        }
        return #"{"total_count":\#(runs.count),"workflow_runs":[\#(items.joined(separator: ","))]}"#
    }
}
