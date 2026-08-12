import Foundation
import GitHubDomain
import LoggingDomain

/// Scans GitHub for Actions jobs that are waiting for a runner.
///
/// GitHub exposes no organisation-wide endpoint for workflow runs or jobs, so a scan costs about
/// one request per repository plus one per unfinished run. Three things keep that affordable:
/// conditional requests (a `304` does not count against the primary rate limit), a bounded
/// concurrency window, and a stale-while-revalidate cache so several dashboards polling at once
/// produce at most one scan.
public actor GitHubActionsScanner: GitHubQueuedJobsProviding {
    enum Constants {
        /// Installation tokens are valid for an hour; refresh early so a scan never starts with
        /// a token that expires mid-flight.
        static let tokenLifetime: TimeInterval = 45 * 60
        static let apiVersion = "2022-11-28"
        static let requestTimeout: TimeInterval = 15
        static let repositoriesPerPage = 100
        static let maxRepositoryPages = 20
    }

    struct CachedResponse: Sendable {
        let etag: String
        let data: Data
    }

    struct RateLimit: Sendable {
        let remaining: Int?
        let resetAt: Date?
    }

    /// Everything one repository's scan produced. The concurrent tasks build these from local
    /// values only, so they never serialise on this actor.
    struct RepositoryScanResult: Sendable {
        var jobs: [GitHubQueuedJob] = []
        var cacheUpdates: [String: CachedResponse] = [:]
        var warnings: [String] = []
        var rateLimit: RateLimit?
        /// The remaining request budget fell below the configured floor.
        var exhausted = false
        /// GitHub rejected the installation token; it needs renewing.
        var tokenRejected = false
    }

    private let client: GitHubClient
    private let credentialsStore: GitHubCredentialsStore
    private let runnerScope: GitHubRunnerScope
    nonisolated let configuration: GitHubScanConfiguration
    nonisolated let logger: Logger
    nonisolated let session: URLSession
    nonisolated let baseURL = URL(string: "https://api.github.com")!

    private var cachedToken: (value: String, fetchedAt: Date)?
    private var cachedRepositories: (value: [String], fetchedAt: Date)?
    private var responseCache = [String: CachedResponse]()
    private var snapshot: GitHubQueuedJobsSnapshot?
    private var inFlight: Task<GitHubQueuedJobsSnapshot, Error>?

    public init(
        client: GitHubClient,
        credentialsStore: GitHubCredentialsStore,
        runnerScope: GitHubRunnerScope,
        configuration: GitHubScanConfiguration,
        logger: Logger,
        session: URLSession = .shared
    ) {
        self.client = client
        self.credentialsStore = credentialsStore
        self.runnerScope = runnerScope
        self.configuration = configuration
        self.logger = logger
        self.session = session
    }

    public func queuedJobs(refresh: Bool) async throws -> GitHubQueuedJobsSnapshot {
        if !refresh, let snapshot {
            if Date().timeIntervalSince(snapshot.scannedAt) < configuration.cacheSeconds {
                return snapshot
            }
            // Serve what we have and refresh behind it. A full scan can take tens of seconds and
            // the caller is holding an HTTP connection open.
            startBackgroundRefresh()
            return snapshot
        }
        return try await coalescedScan()
    }
}

// MARK: - Scan orchestration

private extension GitHubActionsScanner {
    /// Several callers arriving at once share one scan rather than each starting their own.
    func coalescedScan() async throws -> GitHubQueuedJobsSnapshot {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await self.scan() }
        inFlight = task
        defer { inFlight = nil }
        do {
            let result = try await task.value
            snapshot = result
            return result
        } catch {
            // A failed refresh must not discard a usable snapshot.
            if let snapshot {
                return snapshot
            }
            throw error
        }
    }

    func startBackgroundRefresh() {
        guard inFlight == nil else { return }
        let task = Task { try await self.scan() }
        inFlight = task
        Task {
            let result = try? await task.value
            self.finishBackgroundRefresh(with: result)
        }
    }

    func finishBackgroundRefresh(with result: GitHubQueuedJobsSnapshot?) {
        inFlight = nil
        if let result {
            snapshot = result
        }
    }

    func scan() async throws -> GitHubQueuedJobsSnapshot {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(configuration.timeoutSeconds)
        let token = try await accessToken()

        var warnings = [String]()
        var truncated = false

        let discovered = try await repositoryNames(token: token)
        let repositories = discovered.names
        if discovered.truncated {
            truncated = true
            warnings.append("Only the first \(configuration.maxRepositories) repositories were scanned.")
        }

        // Child tasks work from local copies so they never contend on this actor.
        let cacheSnapshot = responseCache
        let runsPerRepository = configuration.runsPerRepository
        let rateLimitFloor = configuration.rateLimitFloor
        let window = min(configuration.maxConcurrentRequests, max(repositories.count, 1))

        var jobs = [GitHubQueuedJob]()
        var cacheUpdates = [String: CachedResponse]()
        var latestRateLimit: RateLimit?
        var scanned = 0
        var exhausted = false
        var tokenRejected = false

        let scanOne: @Sendable (String) async -> RepositoryScanResult = { [self] repository in
            await scanRepository(
                repository,
                token: token,
                cache: cacheSnapshot,
                runsPerRepository: runsPerRepository,
                rateLimitFloor: rateLimitFloor,
                deadline: deadline
            )
        }

        await withTaskGroup(of: RepositoryScanResult.self) { group in
            var next = 0
            while next < window, next < repositories.count {
                let repository = repositories[next]
                group.addTask { await scanOne(repository) }
                next += 1
            }

            while let result = await group.next() {
                scanned += 1
                jobs.append(contentsOf: result.jobs)
                cacheUpdates.merge(result.cacheUpdates) { _, new in new }
                warnings.append(contentsOf: result.warnings)
                if let rateLimit = result.rateLimit { latestRateLimit = rateLimit }
                if result.exhausted { exhausted = true }
                if result.tokenRejected { tokenRejected = true }

                guard !exhausted, Date() < deadline, next < repositories.count else { continue }
                let repository = repositories[next]
                group.addTask { await scanOne(repository) }
                next += 1
            }
        }

        if tokenRejected {
            invalidateToken()
        }
        if exhausted {
            truncated = true
            warnings.append("Stopped early: fewer than \(configuration.rateLimitFloor) GitHub API requests remained.")
        } else if scanned < repositories.count {
            truncated = true
            warnings.append("Stopped after \(Int(configuration.timeoutSeconds))s: scanned \(scanned) of \(repositories.count) repositories.")
        }

        responseCache = trimmed(cache: responseCache.merging(cacheUpdates) { _, new in new })

        let result = GitHubQueuedJobsSnapshot(
            jobs: jobs.sorted { $0.createdAt < $1.createdAt },
            scannedAt: Date(),
            repositoriesScanned: scanned,
            truncated: truncated,
            warnings: dedupedWarnings(warnings),
            rateLimitRemaining: latestRateLimit?.remaining,
            rateLimitResetAt: latestRateLimit?.resetAt
        )
        logger.info("GitHub Scan Completed", parameters: [
            GitHubScanLogKey.repositoryCount: "\(scanned)",
            GitHubScanLogKey.jobCount: "\(result.jobs.count)",
            GitHubScanLogKey.truncated: "\(truncated)",
            GitHubScanLogKey.durationMs: "\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
            GitHubScanLogKey.rateLimitRemaining: latestRateLimit?.remaining.map { "\($0)" } ?? "unknown"
        ])
        return result
    }

    /// Keeps the conditional-request cache from growing without bound as runs come and go.
    func trimmed(cache: [String: CachedResponse]) -> [String: CachedResponse] {
        let limit = configuration.maxRepositories * (configuration.runsPerRepository + 1)
        guard cache.count > limit else { return cache }
        return Dictionary(uniqueKeysWithValues: cache.prefix(limit).map { ($0.key, $0.value) })
    }
}

// MARK: - Repository discovery

private extension GitHubActionsScanner {
    func repositoryNames(token: String) async throws -> (names: [String], truncated: Bool) {
        if let cachedRepositories, Date().timeIntervalSince(cachedRepositories.fetchedAt) < configuration.repositoryCacheSeconds {
            return (cachedRepositories.value, false)
        }

        var names: [String]
        switch runnerScope {
        case .repo:
            guard let ownerName = credentialsStore.ownerName, let repositoryName = credentialsStore.repositoryName else {
                throw GitHubScanError.repositoryScopeIncomplete
            }
            names = ["\(ownerName)/\(repositoryName)"]
        case .organization:
            names = try await installationRepositories(token: token)
        }

        if !configuration.includeRepositories.isEmpty {
            let include = Set(configuration.includeRepositories)
            names = names.filter { include.contains($0) }
        }
        if !configuration.excludeRepositories.isEmpty {
            let exclude = Set(configuration.excludeRepositories)
            names = names.filter { !exclude.contains($0) }
        }

        let truncated = names.count > configuration.maxRepositories
        if truncated {
            names = Array(names.prefix(configuration.maxRepositories))
        }
        cachedRepositories = (names, Date())
        return (names, truncated)
    }

    /// Paginates `/installation/repositories`, newest-pushed first so a repository cap keeps the
    /// repositories most likely to have queued work.
    func installationRepositories(token: String) async throws -> [String] {
        var collected = [GitHubInstallationRepository]()
        var page = 1
        while page <= Constants.maxRepositoryPages {
            let url = baseURL
                .appending(path: "/installation/repositories")
                .appending(queryItems: [
                    URLQueryItem(name: "per_page", value: "\(Constants.repositoriesPerPage)"),
                    URLQueryItem(name: "page", value: "\(page)")
                ])
            let outcome = await fetch(GitHubInstallationRepositoriesPage.self, url: url, token: token, cache: responseCache)
            if let update = outcome.cacheUpdate {
                responseCache[url.absoluteString] = update
            }
            if outcome.tokenRejected {
                invalidateToken()
            }
            guard let value = outcome.value else {
                guard !collected.isEmpty else {
                    throw GitHubScanError.repositoryListUnavailable(
                        outcome.warning ?? "Could not list the installation's repositories"
                    )
                }
                break
            }
            collected.append(contentsOf: value.repositories)
            if value.repositories.count < Constants.repositoriesPerPage || collected.count >= value.totalCount {
                break
            }
            page += 1
        }

        return collected
            .filter { $0.archived != true }
            .sorted { lhs, rhs in
                let lhsDate = GitHubDateParser.date(from: lhs.pushedAt) ?? .distantPast
                let rhsDate = GitHubDateParser.date(from: rhs.pushedAt) ?? .distantPast
                return lhsDate > rhsDate
            }
            .map(\.fullName)
    }

    func accessToken() async throws -> String {
        if let cachedToken, Date().timeIntervalSince(cachedToken.fetchedAt) < Constants.tokenLifetime {
            return cachedToken.value
        }
        let token = try await client.getAppAccessToken(runnerScope: runnerScope)
        cachedToken = (token.rawValue, Date())
        return token.rawValue
    }

    func invalidateToken() {
        cachedToken = nil
    }
}
