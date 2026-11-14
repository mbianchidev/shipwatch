import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession without its own cache, so Shipwatch's ETag handling sees real 304s.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "Shipwatch"]
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw GitHubError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.invalidResponse("Not an HTTP response from \(request.url?.host() ?? "server").")
        }
        return (data, http)
    }
}

public enum GitHubError: Error, Equatable, LocalizedError {
    case notSignedIn
    case unauthorized
    case rateLimited(resetAt: Date?)
    case notFound
    case http(status: Int, message: String)
    case invalidResponse(String)
    case graphQL(String)
    case network(String)

    /// Errors that will hit every other request too, so a refresh should stop instead of degrading per repo.
    public var affectsEveryRequest: Bool {
        switch self {
        case .notSignedIn, .unauthorized, .rateLimited, .network: true
        default: false
        }
    }

    /// A 5xx from GitHub. For GraphQL this usually means the query took too long.
    public var isServerError: Bool {
        if case .http(let status, _) = self { return status >= 500 }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Not signed in to GitHub."
        case .unauthorized:
            "GitHub rejected the token. Sign in again."
        case .rateLimited(let resetAt):
            if let resetAt {
                "GitHub rate limit reached until \(resetAt.formatted(date: .omitted, time: .shortened))."
            } else {
                "GitHub rate limit reached."
            }
        case .notFound:
            "Not found, or the token can't read it."
        case .http(let status, let message):
            "GitHub returned HTTP \(status): \(message)"
        case .invalidResponse(let message):
            "Unexpected response from GitHub: \(message)"
        case .graphQL(let message):
            "GitHub GraphQL error: \(message)"
        case .network(let message):
            "Network error: \(message)"
        }
    }
}

enum JSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let snakeDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, snakeCase: Bool = true) throws -> T {
        do {
            return try (snakeCase ? snakeDecoder : decoder).decode(type, from: data)
        } catch {
            throw GitHubError.invalidResponse("Could not decode \(T.self): \(error)")
        }
    }
}

extension HTTPURLResponse {
    func header(_ name: String) -> String? {
        value(forHTTPHeaderField: name)
    }

    /// The `rel="next"` URL of a GitHub `Link` header.
    var nextPageURL: URL? {
        guard let link = header("Link") else { return nil }
        for part in link.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains("rel=\"next\"") else { continue }
            let target = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: target)
        }
        return nil
    }

    var rateLimit: RateLimit? {
        guard let remaining = header("X-RateLimit-Remaining").flatMap(Int.init),
              let reset = header("X-RateLimit-Reset").flatMap(TimeInterval.init)
        else { return nil }
        return RateLimit(remaining: remaining, resetAt: Date(timeIntervalSince1970: reset))
    }

    /// Primary limit (remaining 0) or secondary limit (`Retry-After`), both reported as 403 or 429.
    func rateLimitError(now: Date = Date()) -> GitHubError? {
        guard statusCode == 403 || statusCode == 429 else { return nil }
        if let retryAfter = header("Retry-After").flatMap(TimeInterval.init) {
            return .rateLimited(resetAt: now.addingTimeInterval(retryAfter))
        }
        if let limit = rateLimit, limit.remaining == 0 {
            return .rateLimited(resetAt: limit.resetAt)
        }
        return nil
    }
}
