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
        guard Date() < deadline else {
            result.truncated = true
            result.warnings.append("Skipped \(repository): scan time budget exhausted.")
            return result
        }

        // Preserve recent runs in every state, including waiting/requested/pending runs. A
        // full page also needs filtered rescue queries: completed runs must not crowd an older
        // queued or in-progress run out of automatic recovery forever.
        let runsURL = baseURL
            .appending(path: "/repos/\(repository)/actions/runs")
            .appending(queryItems: [URLQueryItem(name: "per_page", value: "\(runsPerRepository)")])

        let runsOutcome = await fetch(GitHubWorkflowRunsPage.self, url: runsURL, token: token, cache: cache)
        apply(runsOutcome, url: runsURL, to: &result, rateLimitFloor: rateLimitFloor)
        guard let runsPage = runsOutcome.value else { return result }

        var runs = runsPage.workflowRuns
        if runs.count >= runsPerRepository {
            for status in ["queued", "in_progress"] {
                guard Date() < deadline, !result.exhausted, !result.tokenRejected else {
                    result.truncated = true
                    result.warnings.append("Skipped \(status) run recovery query for \(repository): scan budget exhausted.")
                    continue
                }
                let filteredURL = runsURL.appending(queryItems: [URLQueryItem(name: "status", value: status)])
                let outcome = await fetch(GitHubWorkflowRunsPage.self, url: filteredURL, token: token, cache: cache)
                apply(outcome, url: filteredURL, to: &result, rateLimitFloor: rateLimitFloor)
                guard let page = outcome.value else { continue }
                runs.append(contentsOf: page.workflowRuns)
                if page.totalCount.map({ $0 > page.workflowRuns.count }) ?? (page.workflowRuns.count >= runsPerRepository) {
                    result.truncated = true
                    result.warnings.append("Only the first \(runsPerRepository) \(status) runs for \(repository) were scanned.")
                }
            }
        }

        var seenRuns = Set<Int>()
        for run in runs where run.status != "completed" && seenRuns.insert(run.id).inserted {
            guard Date() < deadline, !result.exhausted, !result.tokenRejected else {
                result.truncated = true
                result.warnings.append("Stopped before scanning all discovered unfinished runs in \(repository): scan budget exhausted.")
                break
            }

            let jobsURL = baseURL
                .appending(path: "/repos/\(repository)/actions/runs/\(run.id)/jobs")
                .appending(queryItems: [
                    URLQueryItem(name: "filter", value: "latest"),
                    URLQueryItem(name: "per_page", value: "100")
                ])
            let jobsOutcome = await fetch(GitHubJobsPage.self, url: jobsURL, token: token, cache: cache)
            apply(jobsOutcome, url: jobsURL, to: &result, rateLimitFloor: rateLimitFloor)
            guard let jobsPage = jobsOutcome.value else { continue }
            if jobsPage.totalCount.map({ $0 > jobsPage.jobs.count }) ?? (jobsPage.jobs.count >= 100) {
                result.truncated = true
                result.warnings.append("Only the first 100 jobs for run \(run.id) in \(repository) were scanned.")
            }

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
        if let warning = outcome.warning {
            result.warnings.append(warning)
            result.truncated = true
        }
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
