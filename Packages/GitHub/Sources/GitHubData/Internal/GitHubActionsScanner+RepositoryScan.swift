import Foundation
import GitHubDomain

// The per-repository scan. Internal rather than file-private so it lives outside the actor's
// main file; every member here is `nonisolated` and touches only immutable state.
// MARK: - Repository scanning (off-actor)

extension GitHubActionsScanner {
    /// Fetches one repository's unfinished runs and the queued jobs inside them. `nonisolated`
    /// so the concurrency window is real — an actor-isolated version would run these one at a
    /// time no matter how many tasks the group holds.
    nonisolated func scanRepository(
        _ repository: String,
        token: String,
        cache: [String: CachedResponse],
        runsPerRepository: Int,
        rateLimitFloor: Int,
        deadline: Date
    ) async -> RepositoryScanResult {
        var result = RepositoryScanResult()

        // One unfiltered page rather than a `status=queued` filter: a run that is itself
        // `in_progress` can still hold a job waiting for a runner, which is the most common way
        // a job gets stuck.
        let runsURL = baseURL
            .appending(path: "/repos/\(repository)/actions/runs")
            .appending(queryItems: [URLQueryItem(name: "per_page", value: "\(runsPerRepository)")])

        let runsOutcome = await fetch(GitHubWorkflowRunsPage.self, url: runsURL, token: token, cache: cache)
        apply(runsOutcome, url: runsURL, to: &result, rateLimitFloor: rateLimitFloor)
        guard let runsPage = runsOutcome.value else { return result }

        for run in runsPage.workflowRuns where run.status != "completed" {
            guard Date() < deadline, !result.exhausted, !result.tokenRejected else { break }

            let jobsURL = baseURL
                .appending(path: "/repos/\(repository)/actions/runs/\(run.id)/jobs")
                .appending(queryItems: [
                    URLQueryItem(name: "filter", value: "latest"),
                    URLQueryItem(name: "per_page", value: "100")
                ])
            let jobsOutcome = await fetch(GitHubJobsPage.self, url: jobsURL, token: token, cache: cache)
            apply(jobsOutcome, url: jobsURL, to: &result, rateLimitFloor: rateLimitFloor)
            guard let jobsPage = jobsOutcome.value else { continue }

            // `waiting` (deployment approval) and `pending` (concurrency slot) are excluded
            // deliberately: neither is unblocked by starting a machine.
            for job in jobsPage.jobs where job.status == "queued" {
                result.jobs.append(GitHubQueuedJob(
                    id: job.id,
                    runId: job.runId,
                    name: job.name,
                    workflowName: job.workflowName,
                    repositoryFullName: repository,
                    htmlURL: job.htmlUrl,
                    labels: Set(job.labels),
                    createdAt: GitHubDateParser.date(from: job.createdAt) ?? Date(),
                    startedAt: GitHubDateParser.date(from: job.startedAt)
                ))
            }
        }
        return result
    }

    nonisolated func apply<T>(
        _ outcome: FetchOutcome<T>,
        url: URL,
        to result: inout RepositoryScanResult,
        rateLimitFloor: Int
    ) {
        if let rateLimit = outcome.rateLimit { result.rateLimit = rateLimit }
        if let update = outcome.cacheUpdate { result.cacheUpdates[url.absoluteString] = update }
        if let warning = outcome.warning { result.warnings.append(warning) }
        if outcome.tokenRejected { result.tokenRejected = true }
        if let remaining = outcome.rateLimit?.remaining, remaining < rateLimitFloor {
            result.exhausted = true
        }
    }

    nonisolated func dedupedWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { seen.insert($0).inserted }
    }
}
