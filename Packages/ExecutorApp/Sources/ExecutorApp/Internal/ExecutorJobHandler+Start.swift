import Foundation
import LoggingDomain
import TartCommon
import VirtualMachineDomain

// Internal so `ExecutorJobHandler+Dispatch` can start a machine for a job the executor
// never received a webhook for.
extension ExecutorJobHandler {
    /// Creates and boots a machine for the job. Returns the machine's name. The assignment to
    /// `activeJobs` happens synchronously before returning, which is what makes the
    /// check-then-start in `dispatch` safe.
    @discardableResult
    func start(pendingJob: ExecutorPendingJob) -> String {
        rememberContext(pendingJob.workflowJob.github ?? .init(workflowJobId: String(pendingJob.id)))
        if let existingJob = activeJobs.values.first(where: { $0.jobId == pendingJob.id }) {
            return existingJob.vmName
        }
        cancelPendingJobRetry(id: pendingJob.id)
        logger.info("Job Executor Starting", pendingJob: pendingJob)
        pendingJob.didStart = true
        let runnerLabels = pendingJob.workflowJob.labels.joined(separator: ",")
        let uuid = UUID()
        let vmName = "\(ExecutorConstants.virtualMachineNamePrefix)\(pendingJob.workflowJob.id)-\(uuid.uuidString)"
        createdJobIDs[vmName] = pendingJob.id
        let task = Task { [weak self, logger, virtualMachineProvider] in
            do {
                logger.info("Virtual Machine Creating", pendingJob: pendingJob, uuid: uuid)
                let virtualMachine = try await virtualMachineProvider.createVirtualMachine(
                    imageName: pendingJob.imageName,
                    name: vmName,
                    runnerLabels: runnerLabels,
                    isInsecure: pendingJob.isInsecure,
                    cpu: pendingJob.cpu,
                    memory: pendingJob.memory
                )

                func delete(error runError: Error? = nil) async throws {
                    do {
                        try await virtualMachine.delete()
                        logger.info("Virtual Machine Deleted", pendingJob: pendingJob, virtualMachine: virtualMachine, uuid: uuid, runError: runError)
                    } catch {
                        logger.error("Virtual Machine Deleting Error", pendingJob: pendingJob, virtualMachine: virtualMachine, uuid: uuid, runError: runError, deleteError: error)
                        throw error
                    }
                }

                try await withTaskCancellationHandler {
                    logger.info("Virtual Machine Starting", pendingJob: pendingJob, virtualMachine: virtualMachine, uuid: uuid)
                    do {
                        try await virtualMachine.start(netBridgedAdapter: pendingJob.netBridgedAdapter, isHeadless: pendingJob.isHeadless)
                        logger.info("Virtual Machine Stopped", pendingJob: pendingJob, virtualMachine: virtualMachine, uuid: uuid)
                        try await delete()
                    } catch {
                        logger.error("Virtual Machine Stopping Error", pendingJob: pendingJob, virtualMachine: virtualMachine, uuid: uuid, error: error)
                        try await delete(error: error)
                        throw error
                    }
                } onCancel: {
                    Task.detached(priority: .high) {
                        logger.info("Virtual Machine Cancelling", pendingJob: pendingJob, virtualMachine: virtualMachine, uuid: uuid)
                        do {
                            try await virtualMachine.delete()
                        } catch {
                            logger.error("Virtual Machine Cancel Deleting Error", pendingJob: pendingJob, virtualMachine: virtualMachine, uuid: uuid, error: error)
                            throw error
                        }
                        await self?.remove(uuid: uuid)
                    }
                }

                await self?.remove(uuid: uuid)
            } catch {
                logger.error("Job Executor Execution Error", pendingJob: pendingJob, uuid: uuid, error: error)
                await self?.remove(uuid: uuid)
            }
        }

        activeJobs[uuid] = .init(
            jobId: pendingJob.id,
            labels: pendingJob.workflowJob.labels,
            task: task,
            cpu: pendingJob.cpu,
            memory: pendingJob.memory,
            vmName: vmName,
            startedAt: Date(),
            imageName: pendingJob.imageName
        )
        return vmName
    }
}
