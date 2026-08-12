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
    func dispatch(id: Int, labels: Set<String>, pinnedHostname: String?, force: Bool) async -> RouterDispatchOutcome {
        if let existingJob = jobs[id], !force {
            logger.error("Job Router Dispatch Skipped Already Tracked", job: existingJob)
            return .skippedAlreadyTracked(
                sentToHost: existingJob.sentToHost?.hostname,
                action: existingJob.workflowJob.action
            )
        }

        let workflowJob = WorkflowJob(id: id, action: .queued, labels: labels)
        let bodyData: Data
        do {
            // The same body a GitHub webhook would have delivered, so the executor sees nothing
            // unusual about a dispatched job.
            bodyData = try JSONEncoder().encode(WebhookResponse(
                action: .queued,
                workflow_job: WebhookResponse.WorkflowJobResponse(id: id, labels: labels)
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
            pinnedHostname: pinnedHostname
        )
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
