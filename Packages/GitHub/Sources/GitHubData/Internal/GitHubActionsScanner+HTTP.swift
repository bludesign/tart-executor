import Foundation
import GitHubDomain
import LoggingDomain

// The scanner's HTTP layer: conditional GETs, rate-limit headers, and the error mapping that
// tells a spent rate limit apart from a missing GitHub App permission.
extension GitHubActionsScanner {
    struct FetchOutcome<T>: Sendable where T: Sendable {
        var value: T?
        var cacheUpdate: CachedResponse?
        var rateLimit: RateLimit?
        var warning: String?
        var tokenRejected = false
    }

    /// Issues a conditional GET and decodes it. A `304` re-decodes the cached body and costs
    /// nothing against the primary rate limit.
    nonisolated func fetch<T: Decodable & Sendable>(
        _ type: T.Type,
        url: URL,
        token: String,
        cache: [String: CachedResponse]
    ) async -> FetchOutcome<T> {
        var outcome = FetchOutcome<T>()
        let cached = cache[url.absoluteString]

        var request = URLRequest(url: url, timeoutInterval: Constants.requestTimeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Constants.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        if let cached {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }
        // URLSession's own cache would answer the conditional request itself and hide the 304.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: HTTPURLResponse
        do {
            let (body, urlResponse) = try await session.data(for: request)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                outcome.warning = "GitHub returned a non-HTTP response for \(url.path)"
                return outcome
            }
            data = body
            response = httpResponse
        } catch {
            outcome.warning = "GitHub request failed for \(url.path): \(error.localizedDescription)"
            return outcome
        }

        outcome.rateLimit = rateLimit(from: response)

        switch response.statusCode {
        case 304:
            guard let cached else { return outcome }
            outcome.value = try? JSONDecoder().decode(T.self, from: cached.data)
            return outcome
        case 200 ..< 300:
            do {
                outcome.value = try JSONDecoder().decode(T.self, from: data)
            } catch {
                outcome.warning = "Could not decode GitHub's response for \(url.path): \(error.localizedDescription)"
                return outcome
            }
            if let etag = response.value(forHTTPHeaderField: "ETag") {
                outcome.cacheUpdate = CachedResponse(etag: etag, data: data)
            }
            return outcome
        case 401:
            outcome.tokenRejected = true
            outcome.warning = "GitHub rejected the installation token. It will be renewed on the next scan."
            return outcome
        case 403, 429:
            outcome.warning = deniedWarning(response: response, data: data, path: url.path)
            return outcome
        default:
            logger.error("GitHub Scan Request Failed", parameters: [
                GitHubScanLogKey.url: url.absoluteString,
                GitHubScanLogKey.statusCode: "\(response.statusCode)"
            ])
            outcome.warning = "GitHub returned \(response.statusCode) for \(url.path)"
            return outcome
        }
    }

    /// Separates the two very different causes of a 403 on an Actions endpoint: a spent rate
    /// limit, or a GitHub App that was never granted `Actions: read`.
    nonisolated func deniedWarning(response: HTTPURLResponse, data: Data, path: String) -> String {
        let remaining = Int(response.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "")
        if response.statusCode == 429 || remaining == 0 {
            let retryAfter = response.value(forHTTPHeaderField: "retry-after").map { " Retry after \($0)s." } ?? ""
            return "GitHub rate limit reached.\(retryAfter)"
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        if body.contains("Resource not accessible by integration") {
            return "The GitHub App is missing the 'Actions: read' permission; approve the permission update on the organization installation."
        }
        return "GitHub denied access to \(path). Check the GitHub App's Actions permission."
    }

    nonisolated func rateLimit(from response: HTTPURLResponse) -> RateLimit {
        let remaining = Int(response.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "")
        let reset = Double(response.value(forHTTPHeaderField: "x-ratelimit-reset") ?? "")
            .map(Date.init(timeIntervalSince1970:))
        return RateLimit(remaining: remaining, resetAt: reset)
    }
}

// MARK: - Errors

public enum GitHubScanError: LocalizedError {
    case repositoryScopeIncomplete
    case repositoryListUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .repositoryScopeIncomplete:
            return "The repository owner and name must both be configured for repo runner scope"
        case let .repositoryListUnavailable(reason):
            return reason
        }
    }
}

/// Local mirror of the shared log keys; TartCommon is not a dependency of this package.
enum GitHubScanLogKey {
    static let url = "url"
    static let statusCode = "status_code"
    static let repositoryCount = "repository_count"
    static let jobCount = "job_count"
    static let durationMs = "duration_ms"
    static let truncated = "truncated"
    static let rateLimitRemaining = "rate_limit_remaining"
}
