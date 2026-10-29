import Foundation
import LoggingDomain
import TartCommon

protocol RouterGitHubReconciling: Sendable {
    func queuedJobs() async throws -> GitHubQueuedJobsResponse
    func job(id: Int, repository: String) async throws -> GitHubJobStatusDTO
    func executorJobs() async throws -> [String: [ExecutorJobDTO]]
}

/// Keeps GitHub credentials on the executors while the router remains the fleet's single
/// scheduling coordinator. An unavailable or unconfigured executor falls through to the next.
actor RouterGitHubReconciler: RouterGitHubReconciling {
    private let hosts: [TartHost]
    private let labels: Set<String>
    private let logger: Logger
    private let apiToken: String?
    private let session: URLSession
    private var preferredHostname: String?

    init(
        hosts: [TartHost],
        labels: Set<String>,
        logger: Logger,
        apiToken: String? = nil,
        session: URLSession = .shared
    ) {
        self.hosts = hosts
        self.labels = labels
        self.logger = logger
        self.apiToken = apiToken
        self.session = session
    }

    func queuedJobs() async throws -> GitHubQueuedJobsResponse {
        let snapshot: GitHubQueuedJobsResponse = try await fetch(
            path: "/api/v1/github/queued-jobs",
            queryItems: [
                URLQueryItem(name: "matching", value: "all"),
                URLQueryItem(name: "refresh", value: "true")
            ],
            totalTimeout: 30,
            sourceTimeout: 30
        ) { snapshot, requestedAt in
            // Even refresh=true may return a cached snapshot if GitHub fails. Such a result
            // is useful to a dashboard but must never provision runners for old queued jobs.
            guard snapshot.scannedAt >= requestedAt.addingTimeInterval(-5),
                  Date().timeIntervalSince(snapshot.scannedAt) <= 60 else {
                throw SourceError.staleSnapshot
            }
        }

        return GitHubQueuedJobsResponse(
            hostname: snapshot.hostname,
            // An executor can reject a job that a different host can run. Match against the
            // router's labels, preserving GitHub's complete label set for runner registration.
            jobs: snapshot.jobs.filter { labels.isSubset(of: Set($0.labels)) },
            scannedAt: snapshot.scannedAt,
            repositoriesScanned: snapshot.repositoriesScanned,
            truncated: snapshot.truncated,
            warnings: snapshot.warnings,
            rateLimitRemaining: snapshot.rateLimitRemaining,
            rateLimitResetAt: snapshot.rateLimitResetAt,
            runnerJobs: snapshot.runnerJobs
        )
    }

    func job(id: Int, repository: String) async throws -> GitHubJobStatusDTO {
        try await fetch(
            path: "/api/v1/github/jobs/\(id)",
            queryItems: [URLQueryItem(name: "repository", value: repository)],
            totalTimeout: 10,
            sourceTimeout: 5
        ) { job, _ in
            guard job.id == id, job.repository.caseInsensitiveCompare(repository) == .orderedSame else {
                throw SourceError.mismatchedJob
            }
        }
    }

    /// A router restart loses attribution while executors may still be booting runners.
    /// Check every host before creating a recovered job's VM on another host.
    func executorJobs() async throws -> [String: [ExecutorJobDTO]] {
        try await withThrowingTaskGroup(of: (String, [ExecutorJobDTO]).self) { group in
            for host in hosts {
                group.addTask { [session, apiToken] in
                    var request = URLRequest(url: host.url.appending(path: "/api/v1/jobs"), timeoutInterval: 5)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    if let apiToken, !apiToken.isEmpty {
                        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
                    }
                    let (data, response) = try await session.data(for: request)
                    guard let response = response as? HTTPURLResponse else { throw SourceError.nonHTTPResponse }
                    guard (200..<300).contains(response.statusCode) else {
                        throw SourceError.httpStatus(response.statusCode)
                    }
                    let result = try JSONDecoder.api.decode(ExecutorJobsResponse.self, from: data)
                    return (host.hostname, result.jobs)
                }
            }
            var result = [String: [ExecutorJobDTO]]()
            for try await (hostname, jobs) in group { result[hostname] = jobs }
            return result
        }
    }

    private func fetch<Value: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        totalTimeout: TimeInterval,
        sourceTimeout: TimeInterval,
        validate: (Value, Date) throws -> Void
    ) async throws -> Value {
        let deadline = Date().addingTimeInterval(totalTimeout)
        let sources = hosts.sorted { lhs, rhs in
            if lhs.hostname == preferredHostname { return rhs.hostname != preferredHostname }
            if rhs.hostname == preferredHostname { return false }
            return lhs.priority < rhs.priority
        }
        var lastError: Error = SourceError.noExecutors
        for host in sources {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SourceError.deadlineExceeded }
            do {
                let requestedAt = Date()
                let url = host.url.appending(path: path).appending(queryItems: queryItems)
                var request = URLRequest(url: url, timeoutInterval: min(sourceTimeout, remaining))
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                if let apiToken, !apiToken.isEmpty {
                    request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
                }
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw SourceError.nonHTTPResponse }
                guard (200..<300).contains(response.statusCode) else {
                    throw SourceError.httpStatus(response.statusCode)
                }
                let value = try JSONDecoder.api.decode(Value.self, from: data)
                try validate(value, requestedAt)
                preferredHostname = host.hostname
                return value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                lastError = error
                logger.error("Router GitHub Reconciliation Source Failed", parameters: [
                    "hostname": host.hostname,
                    "path": path,
                    "error": error.localizedDescription
                ])
            }
        }
        throw lastError
    }
}

private extension RouterGitHubReconciler {
    enum SourceError: LocalizedError {
        case noExecutors
        case nonHTTPResponse
        case httpStatus(Int)
        case staleSnapshot
        case mismatchedJob
        case deadlineExceeded

        var errorDescription: String? {
            switch self {
            case .noExecutors:
                return "No executor is configured as a GitHub reconciliation source"
            case .nonHTTPResponse:
                return "Executor returned a non-HTTP response"
            case let .httpStatus(status):
                return "Executor returned HTTP \(status)"
            case .staleSnapshot:
                return "Executor returned a stale GitHub snapshot"
            case .mismatchedJob:
                return "Executor returned a different GitHub job or repository"
            case .deadlineExceeded:
                return "GitHub reconciliation source requests exceeded their time budget"
            }
        }
    }
}
