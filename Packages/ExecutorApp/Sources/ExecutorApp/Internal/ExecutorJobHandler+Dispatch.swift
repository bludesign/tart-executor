import Foundation
import LoggingDomain
import TartCommon

/// What a manual dispatch actually did. `handle(pendingJob:)` cannot express this — it returns
/// `true` even when the queued path deduped the job away — so dispatch gets its own result type
/// and the endpoint never reports an ambiguous success.
enum ExecutorDispatchOutcome: Sendable {
    case started(vmName: String)
    case skippedVirtualMachineExists(vmName: String)
    case skippedAlreadyTracked(state: ExecutorJobState)
    case skippedAtCapacity(active: Int, limit: Int)
}

extension ExecutorJobHandler {
    /// Starts a virtual machine for a job the executor was never told about, or was told about
    /// and lost. Deliberately **not** `async`: the existing-machine check and the assignment
    /// `start` makes to `activeJobs` must not be separated by a suspension point, or two
    /// concurrent dispatches for one job could both pass the check.
    func dispatch(pendingJob: ExecutorPendingJob, force: Bool) -> ExecutorDispatchOutcome {
        if let existingJob = activeJobs.values.first(where: { $0.jobId == pendingJob.id }) {
            // Force never gets past this. A second machine for a job GitHub will only ever hand
            // to one runner leaves the other idling until the label reaper finds it.
            logger.info("Job Dispatch Skipped Virtual Machine Exists", pendingJob: pendingJob, [
                LogParameterKey.vmName: existingJob.vmName
            ])
            return .skippedVirtualMachineExists(vmName: existingJob.vmName)
        }

        if !force {
            if inProgressJobs[pendingJob.id] != nil {
                logger.info("Job Dispatch Skipped Already Tracked", pendingJob: pendingJob, [
                    LogParameterKey.state: ExecutorJobState.inProgress.rawValue
                ])
                return .skippedAlreadyTracked(state: .inProgress)
            }
            if pendingJobs[pendingJob.id] != nil {
                logger.info("Job Dispatch Skipped Already Tracked", pendingJob: pendingJob, [
                    LogParameterKey.state: ExecutorJobState.pending.rawValue
                ])
                return .skippedAlreadyTracked(state: .pending)
            }
            guard activeJobs.count < numberOfMachines else {
                logger.info("Job Dispatch Skipped At Capacity", pendingJob: pendingJob, [
                    LogParameterKey.activeJobs: "\(activeJobs.count)",
                    LogParameterKey.maxMachines: "\(numberOfMachines)"
                ])
                return .skippedAtCapacity(active: activeJobs.count, limit: numberOfMachines)
            }
        } else if activeJobs.count >= numberOfMachines {
            logger.error("Job Dispatch Forced Over Capacity", pendingJob: pendingJob, [
                LogParameterKey.activeJobs: "\(activeJobs.count)",
                LogParameterKey.maxMachines: "\(numberOfMachines)"
            ])
        }

        // Track it as pending so the webhooks that follow behave: a real "queued" delivery is
        // deduped instead of starting a second machine, and "completed" finds an entry to remove
        // so the idle-machine reaper runs.
        pendingJobs[pendingJob.id] = pendingJob
        logger.info("Job Dispatch Starting", pendingJob: pendingJob, [
            LogParameterKey.forced: "\(force)"
        ])
        return .started(vmName: start(pendingJob: pendingJob))
    }
}
