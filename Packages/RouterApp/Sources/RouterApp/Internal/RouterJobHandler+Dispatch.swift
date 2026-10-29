import FlyingFox
import Foundation
import LoggingDomain
import TartCommon

/// What a manual dispatch actually did on the router.
enum RouterDispatchOutcome: Sendable {
    case sent(hostname: String)
    case skippedAlreadyTracked(sentToHost: String?, action: WorkflowAction)
    /// No executor had capacity, or none matched the job's CPU/memory needs or pinned hostname.
    /// The webhook path only logs this; dispatch reports it so the dashboard can show it.
    case noHostAvailable
}

extension RouterJobHandler {
    /// Queues a job the router was never told about, or was told about and lost, and places it
    /// like any webhook-delivered job. `pinnedHostname` restricts placement to one executor.
    ///
    /// `force` re-places a job the router already tracks, which clears its host attribution. Only
    /// safe once the caller has confirmed no executor holds a machine for the job — the executors'
    /// duplicate guards are per-host and cannot see each other.
    func dispatch(id: Int, labels: Set<String>, pinnedHostname: String?, force: Bool, repository: String? = nil, github: GitHubJobContext? = nil) async -> RouterDispatchOutcome {
        if completedJobs[id] != nil, !force {
            return .skippedAlreadyTracked(sentToHost: nil, action: .completed)
        }
        if let existingJob = jobs[id], !force {
            logger.error("Job Router Dispatch Skipped Already Tracked", job: existingJob)
            return .skippedAlreadyTracked(
                sentToHost: existingJob.sentToHost?.hostname,
                action: existingJob.workflowJob.action
            )
        }

        var context = github ?? GitHubJobContext(workflowJobId: String(id))
        context.repository = context.repository ?? repository
        let workflowJob = WorkflowJob(id: id, action: .queued, labels: labels, github: context)
        let bodyData: Data
        do {
            // The same body a GitHub webhook would have delivered, so the executor sees nothing
            // unusual about a dispatched job.
            var jobPayload = WebhookResponse.WorkflowJobResponse(id: id, labels: labels)
            jobPayload.github = context
            bodyData = try JSONEncoder.api.encode(WebhookResponse(
                action: .queued,
                workflow_job: jobPayload,
                repository: repository.map { .init(fullName: $0) }
            ))
        } catch {
            logger.error("Job Router Dispatch Encoding Failed", error: error, [
                LogParameterKey.jobId: "\(id)"
            ])
            return .noHostAvailable
        }

        let job = RouterPendingJob(
            workflowJob: workflowJob,
            headers: [.contentType: "application/json"],
            bodyData: bodyData,
            pinnedHostname: pinnedHostname,
            repository: repository
        )
        if force {
            completedJobs[id] = nil
            reconciledCompletedJobs.remove(id)
        }
        reconciledAt[id] = nil
        jobs[id] = job
        logger.info("Job Router Dispatch", job: job, [LogParameterKey.forced: "\(force)"])

        await updateStatus()

        // `updateStatus` suspends, so the job may have been replaced or completed meanwhile.
        guard let placedJob = jobs[id], placedJob === job, let host = placedJob.sentToHost else {
            logger.error("Job Router Dispatch No Host Available", job: job)
            return .noHostAvailable
        }
        return .sent(hostname: host.hostname)
    }
}
