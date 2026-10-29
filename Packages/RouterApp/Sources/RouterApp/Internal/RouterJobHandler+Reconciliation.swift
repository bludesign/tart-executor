import Foundation
import TartCommon

extension RouterJobHandler {
    /// Positive GitHub observations repair missed webhooks. An absent job in a partial or
    /// failed queue scan is never evidence that a tracked job finished.
    func reconcileGitHubJobs() async {
        guard let reconciler, !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(45)
        var snapshot: GitHubQueuedJobsResponse?
        do {
            let result = try await reconciler.queuedJobs()
            // A forced scanner refresh may fall back to a cached snapshot after a failure.
            if result.scannedAt >= startedAt.addingTimeInterval(-5) {
                snapshot = result
            } else {
                logger.error("Job Router Reconciliation Ignored Stale Scan")
            }
        } catch {
            logger.error("Job Router Reconciliation Scan Failed", error: error)
        }

        var runnerObservations = snapshot?.runnerJobs ?? []

        var ownership: [String: [ExecutorJobDTO]]?
        do {
            let result = try await reconciler.executorJobs()
            if Set(result.keys) == Set(hosts.map(\.hostname)) { ownership = result }
        } catch {
            // Without a complete fleet inventory an existing runner may still be booting on
            // an unavailable host. Wait instead of creating the same job's VM elsewhere.
            logger.error("Job Router Reconciliation Ownership Check Failed", error: error)
        }

        let candidates = (snapshot?.jobs ?? []).sorted { lhs, rhs in
            (recoveryAttemptedAt[lhs.id] ?? .distantPast, lhs.createdAt, lhs.id)
                < (recoveryAttemptedAt[rhs.id] ?? .distantPast, rhs.createdAt, rhs.id)
        }
        let candidateIDs = Set(candidates.map(\.id))
        recoveryAttemptedAt = recoveryAttemptedAt.filter { candidateIDs.contains($0.key) }
        var recoveryLookups = 0
        for queued in candidates {
            guard !Task.isCancelled, Date() < deadline, recoveryLookups < 40 else { break }
            guard completedJobs[queued.id] == nil else { continue }
            if let existing = jobs[queued.id] {
                // Manual dispatches made without repository metadata can acquire it here.
                if existing.repository == nil { existing.repository = queued.repository }
                continue
            }
            guard runnerLabels.isSubset(of: Set(queued.labels)) else { continue }
            guard let ownership else { continue }
            // Pending executor work also counts as owned: it may start after backoff even
            // when it has no VM yet. Let that executor finish provisioning or retrying it.
            guard !ownership.values.contains(where: { jobs in jobs.contains { $0.id == queued.id } }) else { continue }
            recoveryLookups += 1
            recoveryAttemptedAt[queued.id] = Date()
            do {
                // Check again immediately before recovery: the job may have started or
                // completed while the repository scan was in flight.
                let status = try await reconciler.job(id: queued.id, repository: queued.repository)
                guard jobs[queued.id] == nil, completedJobs[queued.id] == nil else { continue }
                guard status.id == queued.id, status.repository == queued.repository else { continue }
                if status.status == "completed" {
                    rememberCompletedJob(id: queued.id)
                    continue
                }
                guard status.status == "queued", runnerLabels.isSubset(of: Set(status.labels)) else { continue }
                let workflowJob = WorkflowJob(
                    id: status.id, action: .queued, labels: Set(status.labels), github: status.github ?? queued.github
                )
                let payload = WebhookResponse(
                    action: .queued,
                    workflow_job: .init(id: status.id, labels: workflowJob.labels),
                    repository: .init(fullName: status.repository)
                )
                let job = RouterPendingJob(
                    workflowJob: workflowJob,
                    headers: [.contentType: "application/json"],
                    bodyData: try JSONEncoder.api.encode(payload),
                    pinnedHostname: nil,
                    repository: status.repository
                )
                jobs[job.id] = job
                reconciledAt[job.id] = Date()
                logger.info("Job Router Recovered Missed Queued Job", job: job)
            } catch {
                logger.error("Job Router Recovery Status Failed", error: error, [LogParameterKey.jobId: "\(queued.id)"])
            }
        }
        let statusDeadline = Date().addingTimeInterval(15)
        // Rotate through tracked jobs so a busy repository cannot starve older jobs of checks.
        let tracked = jobs.values.filter { $0.repository != nil }.sorted { lhs, rhs in
            (reconciledAt[lhs.id] ?? .distantPast, lhs.id) < (reconciledAt[rhs.id] ?? .distantPast, rhs.id)
        }
        for job in tracked.prefix(40) {
            guard !Task.isCancelled, Date() < statusDeadline else { break }
            guard jobs[job.id] === job, let repository = job.repository else { continue }
            reconciledAt[job.id] = Date()
            do {
                let status = try await reconciler.job(id: job.id, repository: repository)
                guard jobs[job.id] === job else { continue }
                if let context = status.github { runnerObservations.append(context) }
                applyGitHubStatus(status, to: job, ownership: ownership)
            } catch {
                logger.error("Job Router Reconciliation Status Failed", job: job, error: error)
            }
        }

        if !Task.isCancelled {
            if !runnerObservations.isEmpty {
                let observations = runnerObservations
                Task { await self.broadcastObservations(observations) }
            }
            await updateStatus()
        }
    }

    func rememberCompletedJob(id: Int, cancelMachines: Bool = true) {
        let now = Date()
        completedJobs = completedJobs.filter { now.timeIntervalSince($0.value) < 86_400 }
        if completedJobs.count >= 10_000, let oldest = completedJobs.min(by: { $0.value < $1.value })?.key {
            completedJobs[oldest] = nil
        }
        completedJobs[id] = now
        reconciledCompletedJobs = reconciledCompletedJobs.filter { completedJobs[$0] != nil }
        if cancelMachines {
            reconciledCompletedJobs.remove(id)
        } else {
            reconciledCompletedJobs.insert(id)
        }
    }

    private func applyGitHubStatus(_ status: GitHubJobStatusDTO, to job: RouterPendingJob, ownership: [String: [ExecutorJobDTO]]?) {
        guard status.id == job.id, status.repository == job.repository else { return }
        if let context = status.github {
            let merged = job.workflowJob.github.map { $0.merging(context) } ?? context
            job.workflowJob = WorkflowJob(
                id: job.id, action: job.workflowJob.action, labels: job.workflowJob.labels, github: merged
            )
        }
        switch status.status {
        case "completed":
            jobs[job.id] = nil
            reconciledAt[job.id] = nil
            rememberCompletedJob(id: job.id, cancelMachines: false)
            // The VM named for this job may now be running another matching job. Repair the
            // bookkeeping without cancelling runners by their original job ID or labels.
            logger.info("Job Router Reconciled Completed Job", job: job)
        case "in_progress":
            job.workflowJob = WorkflowJob(id: job.id, action: .inProgress, labels: job.workflowJob.labels, github: job.workflowJob.github)
            if let runnerName = status.runnerName,
               let host = hosts.first(where: { host in
                   ownership?[host.hostname]?.contains { $0.vmName == runnerName } == true
               }) {
                job.sentToHost = host
                // GitHub can assign a VM to another compatible job. Free the queued job's
                // attribution so it can get a replacement instead of waiting for this run.
                if let creatorID = ownership?[host.hostname]?.first(where: { $0.vmName == runnerName })?.id,
                   creatorID != job.id, let donor = jobs[creatorID], donor.sentToHost === host,
                   donor.workflowJob.action == .queued {
                    donor.sentToHost = nil
                }
            } else {
                adoptHostAttribution(for: job)
            }
        default:
            break
        }
    }
}
