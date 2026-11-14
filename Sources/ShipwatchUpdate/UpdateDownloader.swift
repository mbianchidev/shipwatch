import Foundation

package enum UpdateDownloadError: Error, Equatable, LocalizedError {
    case untrustedLocation(String)
    case httpStatus(Int)
    /// GitHub's REST API allows 60 requests an hour per network without a token.
    case rateLimited(until: Date?)
    case tooLarge
    case sizeMismatch(expected: Int64, actual: Int64)
    case storage(String)
    case network(String)
    case cancelled

    package var errorDescription: String? {
        switch self {
        case .untrustedLocation(let host):
            "The download was redirected to an untrusted location (\(host))."
        case .httpStatus(let status):
            "GitHub returned HTTP \(status)."
        case .rateLimited(let until):
            if let until {
                "GitHub's rate limit for this network is used up until \(until.formatted(date: .omitted, time: .shortened))."
            } else {
                "GitHub's rate limit for this network is used up."
            }
        case .tooLarge:
            "The download is larger than allowed."
        case .sizeMismatch(let expected, let actual):
            "The download was \(actual) bytes, but the release lists \(expected)."
        case .storage(let message):
            "The download could not be saved: \(message)"
        case .network(let message):
            "Network error: \(message)"
        case .cancelled:
            "The download was cancelled."
        }
    }
}

/// HTTPS transfers for the update feed and release assets, restricted to GitHub hosts and bounded in size.
/// Uses its own ephemeral session, so no cookies, cache or GitHub token are ever attached.
package struct UpdateDownloader: Sendable {
    package static let feedHosts: Set<String> = ["api.github.com"]
    package static let pageHosts: Set<String> = ["github.com"]
    package static let assetHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]
    /// Without a reset time, the API isn't asked again for this long.
    package static let defaultRateLimitWait: TimeInterval = 60 * 60
    private static let maxPageResponseSize: Int64 = 64 << 10

    private let userAgent: String

    package init(appVersion: String) {
        userAgent = "Shipwatch/\(appVersion)"
    }

    package static func allowsRedirect(to url: URL?, hosts: Set<String>) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), hosts.contains(host),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    /// A 429, or a 403 whose headers say the rate limit is used up, with the time it resets.
    package static func rateLimitError(_ response: HTTPURLResponse, now: Date = Date()) -> UpdateDownloadError? {
        guard response.statusCode == 403 || response.statusCode == 429 else { return nil }
        if let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init), seconds >= 0 {
            return .rateLimited(until: now.addingTimeInterval(seconds))
        }
        guard response.statusCode == 429 || response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" else { return nil }
        let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        return .rateLimited(until: reset)
    }

    package func fetchFeed() async throws -> Data {
        var request = request(for: UpdateFeed.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return try await transfer(request, hosts: Self.feedHosts, limit: UpdateFeed.maxFeedSize).data
    }

    /// Where `UpdateFeed.latestReleasePageURL` redirects, without following it. Used when the API is rate limited.
    package func fetchLatestReleaseLocation() async throws -> URL {
        var request = request(for: UpdateFeed.latestReleasePageURL)
        request.httpMethod = "HEAD"
        let result = try await transfer(request, hosts: Self.pageHosts, limit: Self.maxPageResponseSize, followsRedirects: false)
        guard let location = result.redirect else { throw UpdateFeedError.invalidResponse }
        return location
    }

    /// Downloads a small asset into memory, at most its size limit and exactly its listed size when known.
    package func fetch(_ asset: UpdateAsset) async throws -> Data {
        try await transfer(assetRequest(asset), hosts: Self.assetHosts, limit: asset.size ?? asset.maxSize, exactSize: asset.size).data
    }

    /// Streams an asset to a new file at `destination`, reporting progress from 0 to 1.
    package func download(_ asset: UpdateAsset, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw UpdateDownloadError.storage("could not create \(destination.lastPathComponent)")
        }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        _ = try await transfer(
            assetRequest(asset), hosts: Self.assetHosts, limit: asset.size ?? asset.maxSize, exactSize: asset.size,
            file: file, progress: progress
        )
        try file.synchronize()
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func assetRequest(_ asset: UpdateAsset) -> URLRequest {
        var request = request(for: asset.url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return request
    }

    private func transfer(
        _ request: URLRequest,
        hosts: Set<String>,
        limit: Int64,
        exactSize: Int64? = nil,
        followsRedirects: Bool = true,
        file: FileHandle? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TransferResult {
        guard Self.allowsRedirect(to: request.url, hosts: hosts) else {
            throw UpdateDownloadError.untrustedLocation(request.url?.host ?? "invalid URL")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let delegate = TransferDelegate(
            hosts: hosts, limit: limit, exactSize: exactSize, followsRedirects: followsRedirects, file: file, progress: progress
        )
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private struct TransferResult: Sendable {
    var data: Data
    /// Where the server redirected to, when redirects aren't followed.
    var redirect: URL?
}

private final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let hosts: Set<String>
    private let limit: Int64
    private let exactSize: Int64?
    private let followsRedirects: Bool
    private let file: FileHandle?
    private let progress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<TransferResult, Error>?
    private var buffer = Data()
    private var received: Int64 = 0
    private var expectedSize: Int64?
    private var redirect: URL?
    private var reportedPercent = -1
    private var failure: UpdateDownloadError?

    init(
        hosts: Set<String>, limit: Int64, exactSize: Int64?, followsRedirects: Bool, file: FileHandle?,
        progress: (@Sendable (Double) -> Void)?
    ) {
        self.hosts = hosts
        self.limit = limit
        self.exactSize = exactSize
        self.followsRedirects = followsRedirects
        self.file = file
        self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<TransferResult, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard UpdateDownloader.allowsRedirect(to: request.url, hosts: hosts) else {
            record(.untrustedLocation(request.url?.host ?? "invalid URL"))
            completionHandler(nil)
            task.cancel()
            return
        }
        if followsRedirects {
            completionHandler(request)
        } else {
            // Declining delivers the redirect response itself, which `didReceive response` accepts.
            lock.withLock { redirect = request.url }
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            record(.httpStatus(0))
            completionHandler(.cancel)
            return
        }
        if let rateLimited = UpdateDownloader.rateLimitError(http) {
            record(rateLimited)
            completionHandler(.cancel)
            return
        }
        let redirected = lock.withLock { redirect != nil }
        guard http.statusCode == 200 || (redirected && (300..<400).contains(http.statusCode)) else {
            record(.httpStatus(http.statusCode))
            completionHandler(.cancel)
            return
        }
        guard http.expectedContentLength <= limit else {
            record(.tooLarge)
            completionHandler(.cancel)
            return
        }
        lock.withLock { expectedSize = exactSize ?? (http.expectedContentLength > 0 ? http.expectedContentLength : nil) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let total: Int64 = lock.withLock {
            received += Int64(data.count)
            return received
        }
        guard total <= limit else {
            record(.tooLarge)
            dataTask.cancel()
            return
        }
        if let file {
            do {
                try file.write(contentsOf: data)
            } catch {
                record(.storage(error.localizedDescription))
                dataTask.cancel()
                return
            }
        } else {
            lock.withLock { buffer.append(data) }
        }
        reportProgress(total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, failure, received, buffer, redirect) = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            return (pending, self.failure, self.received, self.buffer, self.redirect)
        }
        guard let continuation else { return }
        if let failure {
            continuation.resume(throwing: failure)
        } else if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            continuation.resume(throwing: cancelled ? UpdateDownloadError.cancelled : UpdateDownloadError.network(error.localizedDescription))
        } else if let exactSize, received != exactSize {
            continuation.resume(throwing: UpdateDownloadError.sizeMismatch(expected: exactSize, actual: received))
        } else {
            continuation.resume(returning: TransferResult(data: buffer, redirect: redirect))
        }
    }

    private func record(_ error: UpdateDownloadError) {
        lock.withLock {
            if failure == nil { failure = error }
        }
    }

    /// Against the listed size, or the response's length when the release was found without the API.
    private func reportProgress(_ total: Int64) {
        guard let progress else { return }
        let percent: Int? = lock.withLock {
            guard let expectedSize, expectedSize > 0 else { return nil }
            let percent = Int(min(total, expectedSize) * 100 / expectedSize)
            guard percent != reportedPercent else { return nil }
            reportedPercent = percent
            return percent
        }
        if let percent { progress(Double(percent) / 100) }
    }
}
