import Foundation
import LoggingDomain

extension ExecutorJobHandler {
    struct PendingJobRetry {
        let token: UUID
        let task: Task<Void, Never>
    }

    func startNextPendingJob() {
        guard hasVirtualMachineSlot else { return }
        let activeJobIds = Set(activeJobs.values.map(\.jobId))
        guard let pendingJob = pendingJobs.values
            .filter({ job in
                !job.didStart && pendingJobRetries[job.id] == nil &&
                    !activeJobIds.contains(job.id) && hasResources(for: job)
            })
            .min(by: { $0.queuedAt < $1.queuedAt }) else { return }
        start(pendingJob: pendingJob)
    }

    func cancelPendingJobRetry(id: Int) {
        pendingJobRetries.removeValue(forKey: id)?.task.cancel()
    }

    func schedulePendingJobRetry(_ pendingJob: ExecutorPendingJob) {
        cancelPendingJobRetry(id: pendingJob.id)
        pendingJob.didStart = false
        let token = UUID()
        let task = Task { [weak self, waitForPendingJobRetry] in
            do {
                // A failed image pull or boot must not spin indefinitely at full speed.
                try await waitForPendingJobRetry()
                try Task.checkCancellation()
                await self?.retryPendingJob(pendingJob, token: token)
            } catch {
                // Completion, cancellation, or a new VM makes the retry unnecessary.
            }
        }
        pendingJobRetries[pendingJob.id] = PendingJobRetry(token: token, task: task)
    }

    private func retryPendingJob(_ pendingJob: ExecutorPendingJob, token: UUID) {
        guard pendingJobRetries[pendingJob.id]?.token == token else { return }
        pendingJobRetries.removeValue(forKey: pendingJob.id)
        guard pendingJobs[pendingJob.id] === pendingJob, inProgressJobs[pendingJob.id] == nil,
              !activeJobs.values.contains(where: { $0.jobId == pendingJob.id }) else { return }
        pendingJob.didStart = false
        logger.info("Job Executor Retrying Pending Job", pendingJob: pendingJob)
        startNextPendingJob()
    }
}
