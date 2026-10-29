import Foundation
import GitHubDomain

extension GitHubActionsScanner {
    /// Display callers share a short-lived result; safety-critical `job` lookups bypass this.
    public func jobDetails(id: Int, repository: String) async throws -> GitHubJobStatus {
        guard id > 0 else { throw GitHubJobLookupError.invalidJobId }
        guard GitHubJobStatus.isValidRepository(repository) else {
            throw GitHubJobLookupError.invalidRepository
        }
        let key = "\(repository.lowercased())/\(id)"
        if let cached = detailCache[key], Date().timeIntervalSince(cached.fetchedAt) < configuration.cacheSeconds {
            return cached.value
        }
        if let task = detailTasks[key] { return try await task.value }

        let task = Task {
            let deadline = Date().addingTimeInterval(configuration.timeoutSeconds)
            let url = baseURL.appending(path: "/repos/\(repository)/actions/jobs/\(id)")
            let job: GitHubJob = try await displayFetch(url: url, deadline: deadline)
            guard job.id == id else { throw GitHubJobLookupError.mismatchedJobId }
            // Run enrichment is optional: a denied run lookup must not hide usable job details.
            let run = try? await runDetails(id: job.runId, repository: repository, deadline: deadline)
            try Task.checkCancellation()
            return job.asStatus(repository: repository, run: run)
        }
        detailTasks[key] = task
        defer { detailTasks[key] = nil }
        let result = try await task.value
        detailCache[key] = (result, Date())
        trimDetailCaches()
        return result
    }

    func runDetails(id: Int, repository: String, deadline: Date) async throws -> GitHubWorkflowRunDetails {
        let key = "\(repository.lowercased())/\(id)"
        if let cached = runDetailCache[key], Date().timeIntervalSince(cached.fetchedAt) < configuration.cacheSeconds {
            return cached.value
        }
        if let task = runDetailTasks[key] { return try await task.value }
        let task = Task {
            let url = baseURL.appending(path: "/repos/\(repository)/actions/runs/\(id)")
            let run: GitHubWorkflowRunDetails = try await displayFetch(url: url, deadline: deadline)
            guard run.id == id else { throw GitHubJobLookupError.unavailable("GitHub returned a different workflow run") }
            return run
        }
        runDetailTasks[key] = task
        defer { runDetailTasks[key] = nil }
        let result = try await task.value
        runDetailCache[key] = (result, Date())
        return result
    }

    func displayFetch<Value: Decodable & Sendable>(url: URL, deadline: Date) async throws -> Value {
        await acquireDisplayRequestSlot()
        defer { releaseDisplayRequestSlot() }
        try Task.checkCancellation()
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw GitHubJobLookupError.unavailable("GitHub detail lookup exceeded its time budget") }
        if let limit = displayRateLimit, let requests = limit.value.remaining, requests < configuration.rateLimitFloor {
            let resumeAt = limit.value.resetAt ?? limit.checkedAt.addingTimeInterval(max(1, configuration.cacheSeconds))
            guard Date() >= resumeAt else {
                throw GitHubJobLookupError.unavailable("GitHub detail lookup paused at the configured rate-limit floor")
            }
        }
        let token = try await accessToken()
        let outcome = await fetch(
            Value.self, url: url, token: token, cache: detailResponses,
            timeout: min(Constants.requestTimeout, remaining)
        )
        if let limit = outcome.rateLimit { displayRateLimit = (limit, Date()) }
        if outcome.tokenRejected { invalidateToken() }
        guard let value = outcome.value else {
            throw GitHubJobLookupError.unavailable(outcome.warning ?? "GitHub job details are unavailable")
        }
        if let update = outcome.cacheUpdate { detailResponses[url.absoluteString] = update }
        return value
    }

    func acquireDisplayRequestSlot() async {
        if activeDisplayRequests < configuration.maxConcurrentRequests {
            activeDisplayRequests += 1
            return
        }
        await withCheckedContinuation { displayRequestWaiters.append($0) }
    }

    func releaseDisplayRequestSlot() {
        if displayRequestWaiters.isEmpty {
            activeDisplayRequests -= 1
        } else {
            displayRequestWaiters.removeFirst().resume()
        }
    }

    func trimDetailCaches() {
        let limit = configuration.maxRepositories * (configuration.runsPerRepository + 1)
        if detailCache.count > limit {
            detailCache = Dictionary(uniqueKeysWithValues: detailCache.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(limit).map { ($0.key, $0.value) })
        }
        if runDetailCache.count > limit {
            runDetailCache = Dictionary(uniqueKeysWithValues: runDetailCache.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(limit).map { ($0.key, $0.value) })
        }
        if detailResponses.count > limit * 2 {
            detailResponses = Dictionary(uniqueKeysWithValues: detailResponses.prefix(limit * 2).map { ($0.key, $0.value) })
        }
    }
}
