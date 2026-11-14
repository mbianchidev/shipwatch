import Foundation

package enum UpdateDownloadError: Error, Equatable, LocalizedError {
    case untrustedLocation(String)
    case httpStatus(Int)
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
    package static let assetHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

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

    package func fetchFeed() async throws -> Data {
        var request = request(for: UpdateFeed.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return try await transfer(request, hosts: Self.feedHosts, limit: UpdateFeed.maxFeedSize)
    }

    /// Downloads a small asset into memory; its size must match the release listing exactly.
    package func fetch(_ asset: UpdateAsset) async throws -> Data {
        try await transfer(assetRequest(asset), hosts: Self.assetHosts, limit: asset.size, exactSize: asset.size)
    }

    /// Streams an asset to a new file at `destination`, reporting progress from 0 to 1.
    package func download(_ asset: UpdateAsset, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw UpdateDownloadError.storage("could not create \(destination.lastPathComponent)")
        }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        _ = try await transfer(
            assetRequest(asset), hosts: Self.assetHosts, limit: asset.size, exactSize: asset.size,
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
        file: FileHandle? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
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
        let delegate = TransferDelegate(hosts: hosts, limit: limit, exactSize: exactSize, file: file, progress: progress)
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

private final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let hosts: Set<String>
    private let limit: Int64
    private let exactSize: Int64?
    private let file: FileHandle?
    private let progress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<Data, Error>?
    private var buffer = Data()
    private var received: Int64 = 0
    private var reportedPercent = -1
    private var failure: UpdateDownloadError?

    init(hosts: Set<String>, limit: Int64, exactSize: Int64?, file: FileHandle?, progress: (@Sendable (Double) -> Void)?) {
        self.hosts = hosts
        self.limit = limit
        self.exactSize = exactSize
        self.file = file
        self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<Data, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if UpdateDownloader.allowsRedirect(to: request.url, hosts: hosts) {
            completionHandler(request)
        } else {
            record(.untrustedLocation(request.url?.host ?? "invalid URL"))
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            record(.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0))
            completionHandler(.cancel)
            return
        }
        guard http.expectedContentLength <= limit else {
            record(.tooLarge)
            completionHandler(.cancel)
            return
        }
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
        let (continuation, failure, received, buffer) = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            return (pending, self.failure, self.received, self.buffer)
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
            continuation.resume(returning: buffer)
        }
    }

    private func record(_ error: UpdateDownloadError) {
        lock.withLock {
            if failure == nil { failure = error }
        }
    }

    private func reportProgress(_ total: Int64) {
        guard let progress, let exactSize, exactSize > 0 else { return }
        let percent = Int(total * 100 / exactSize)
        let changed = lock.withLock {
            guard percent != reportedPercent else { return false }
            reportedPercent = percent
            return true
        }
        if changed { progress(Double(percent) / 100) }
    }
}
