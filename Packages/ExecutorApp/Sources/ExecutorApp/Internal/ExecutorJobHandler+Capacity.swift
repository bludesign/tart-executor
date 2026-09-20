import TartCommon

// Shared by webhook handling and the management dispatch path so every non-forced VM start
// observes the same VM-count and aggregate-resource limits.
extension ExecutorJobHandler {
    var hasVirtualMachineSlot: Bool {
        activeJobs.count < numberOfMachines
    }

    var resourceCapacity: ResourceCapacity {
        let status = jobStatus
        return ResourceCapacity(
            cpuLimit: cpuLimit,
            cpuUsed: status.cpuUsed,
            memoryLimit: totalMemory,
            memoryUsed: status.memoryUsed
        )
    }

    func hasResources(for pendingJob: ExecutorPendingJob) -> Bool {
        resourceCapacity.canFit(.init(cpu: pendingJob.cpu, memory: pendingJob.memory))
    }

    func startIfCapacityAllows(_ pendingJob: ExecutorPendingJob) {
        guard hasVirtualMachineSlot else {
            logVirtualMachineLimitReached(pendingJob)
            return
        }
        guard hasResources(for: pendingJob) else {
            logResourceCapacityReached(pendingJob)
            return
        }
        start(pendingJob: pendingJob)
    }

    func logVirtualMachineLimitReached(_ pendingJob: ExecutorPendingJob) {
        logger.info("Job Executor Virtual Machine Limit Reached", pendingJob: pendingJob, [
            LogParameterKey.activeVirtualMachines: "\(activeJobs.count)",
            LogParameterKey.virtualMachineLimit: "\(numberOfMachines)"
        ])
    }

    func logResourceCapacityReached(_ pendingJob: ExecutorPendingJob) {
        let status = jobStatus
        logger.info("Job Executor Aggregate Resource Capacity Reached", pendingJob: pendingJob, [
            LogParameterKey.cpu: pendingJob.cpu.map(String.init) ?? "unknown",
            LogParameterKey.cpuUsed: "\(status.cpuUsed)",
            LogParameterKey.cpuLimit: "\(cpuLimit)",
            LogParameterKey.memory: pendingJob.memory.map(String.init) ?? "unknown",
            LogParameterKey.memoryUsed: "\(status.memoryUsed)",
            LogParameterKey.memoryLimit: "\(totalMemory)"
        ])
    }
}
