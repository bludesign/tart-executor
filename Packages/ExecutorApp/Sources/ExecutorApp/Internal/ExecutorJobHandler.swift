import Foundation
import LoggingDomain
import TartCommon
import VirtualMachineDomain

struct ActiveJob {
    let labels: Set<String>
    let task: Task<(), Never>
    let cpu: Int?
    let memory: Int?
}

actor ExecutorJobHandler {
    private let numberOfMachines: Int
    private var activeJobs = [UUID: ActiveJob]()
    private var inProgressJobs = [Int: ExecutorPendingJob]()
    private var pendingJobs = [Int: ExecutorPendingJob]()
    private nonisolated let routerUrl: String?
    private nonisolated let virtualMachineProvider: VirtualMachineProvider
    private nonisolated let logger: Logger

    var jobStatus: JobStatus {
        .init(
            inProgressJobs: inProgressJobs.count,
            pendingJobs: pendingJobs.count,
            startedPendingJobs: pendingJobs.filter { $1.didStart }.count,
            virtualMachines: activeJobs.count,
            cpuUsed: activeJobs.reduce(0) { $0 + ($1.value.cpu ?? 0) },
            memoryUsed: activeJobs.reduce(0) { $0 + ($1.value.memory ?? 0) }
        )
    }

    init(routerUrl: String?, virtualMachineProvider: VirtualMachineProvider, logger: Logger, numberOfMachines: Int) {
        self.routerUrl = routerUrl
        self.virtualMachineProvider = virtualMachineProvider
        self.logger = logger
        self.numberOfMachines = numberOfMachines

        Task {
           await activeJobEnded()
        }
    }

    func handle(pendingJob: ExecutorPendingJob) -> Bool {
        switch pendingJob.action {
        case .routerStart:
            logger.info("Router start job added", parameters: [
                LogParameterKey.jobId: "\(pendingJob.id)",
                LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)",
                LogParameterKey.willStart: "\(activeJobs.count < numberOfMachines)",
                LogParameterKey.activeJobs: "\(activeJobs.count)",
                LogParameterKey.maxMachines: "\(numberOfMachines)"
            ])

            if activeJobs.count < numberOfMachines {
                start(pendingJob: pendingJob)
            } else {
                return false
            }
        case .waiting:
            logger.info("Waiting job added", parameters: [
                LogParameterKey.jobId: "\(pendingJob.id)",
                LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)"
            ])
        case .queued:
            logger.info("Pending job added", parameters: [
                LogParameterKey.jobId: "\(pendingJob.id)",
                LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)"
            ])
            pendingJobs[pendingJob.id] = pendingJob

            if activeJobs.count < numberOfMachines {
                start(pendingJob: pendingJob)
            }
        case .inProgress:
            logger.info("In progress job added", parameters: [
                LogParameterKey.jobId: "\(pendingJob.id)",
                LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)"
            ])
            let oldJob = pendingJobs.removeValue(forKey: pendingJob.id)
            if let oldJob, !oldJob.didStart {
                pendingJobs.values.first { existingJob in
                    existingJob.workflowJob.labels == pendingJob.workflowJob.labels && existingJob.didStart
                }?.didStart = false
            }
            inProgressJobs[pendingJob.id] = pendingJob
        case .completed:
            logger.info("Completed job added", parameters: [
                LogParameterKey.jobId: "\(pendingJob.id)",
                LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)"
            ])
            inProgressJobs.removeValue(forKey: pendingJob.id)
            guard pendingJobs[pendingJob.id] != nil else {
                return true
            }
            pendingJobs.removeValue(forKey: pendingJob.id)
            let otherPending = pendingJobs.values.filter { existingJob in
                existingJob.workflowJob.labels == pendingJob.workflowJob.labels
            }.count
            let otherInProgress = inProgressJobs.values.filter { existingJob in
                existingJob.workflowJob.labels == pendingJob.workflowJob.labels
            }.count
            let running = activeJobs.values.filter { activeJob in
                activeJob.labels == pendingJob.workflowJob.labels
            }.count
            if otherPending == 0, otherInProgress == 0 {
                cancelJobsByLabels(pendingJob.workflowJob.labels)
            } else if otherInProgress <= running {
                pendingJobs.values.first { existingJob in
                    existingJob.workflowJob.labels == pendingJob.workflowJob.labels && !existingJob.didStart
                }?.didStart = true
            }
        case .unknown:
            logger.info("Unknown job added", parameters: [
                LogParameterKey.jobId: "\(pendingJob.id)",
                LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)"
            ])
        }
        return true
    }

    func cancelAll() {
        for (_, job) in activeJobs {
            job.task.cancel()
        }
    }

    func cancelJobsByLabels(_ labels: Set<String>) {
        var cancalledJobs = 0
        activeJobs.forEach { _, activeJob in
            guard activeJob.labels == labels else {
                return
            }
            cancalledJobs += 1
            activeJob.task.cancel()
        }
        logger.info("Cancelled jobs with labels", parameters: [
            LogParameterKey.cancelledCount: "\(cancalledJobs)",
            LogParameterKey.labels: labels.joined(separator: ",")
        ])
    }
}

private extension ExecutorJobHandler {
    func start(pendingJob: ExecutorPendingJob) {
        logger.info("Starting job", parameters: [
            LogParameterKey.jobId: "\(pendingJob.id)",
            LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)",
            LogParameterKey.imageName: pendingJob.imageName
        ])
        pendingJob.didStart = true
        let runnerLabels = pendingJob.workflowJob.labels.joined(separator: ",")
        let uuid = UUID()
        let task = Task { [weak self, logger, virtualMachineProvider] in
            do {
                logger.info("Creating virtual machine", parameters: [
                    LogParameterKey.imageName: pendingJob.imageName,
                    LogParameterKey.jobId: "\(pendingJob.id)",
                    LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)",
                    LogParameterKey.uuid: uuid.uuidString
                ])
                let virtualMachine = try await virtualMachineProvider.createVirtualMachine(
                    imageName: pendingJob.imageName,
                    name: "tart-executor-\(pendingJob.workflowJob.id)-\(uuid.uuidString)",
                    runnerLabels: runnerLabels,
                    isInsecure: pendingJob.isInsecure,
                    cpu: pendingJob.cpu,
                    memory: pendingJob.memory
                )

                func delete(error runError: Error? = nil) async throws {
                    do {
                        try await virtualMachine.delete()
                        logger.info("Did delete virtual machine", parameters: [
                            LogParameterKey.vmName: virtualMachine.name,
                            LogParameterKey.jobId: "\(pendingJob.id)",
                            LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)",
                            LogParameterKey.uuid: uuid.uuidString,
                            LogParameterKey.runError: runError?.localizedDescription ?? "none"
                        ])
                    } catch {
                        logger.info("Could not delete virtual machine", parameters: [
                            LogParameterKey.vmName: virtualMachine.name,
                            LogParameterKey.jobId: "\(pendingJob.id)",
                            LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)",
                            LogParameterKey.uuid: uuid.uuidString,
                            LogParameterKey.deleteError: error.localizedDescription,
                            LogParameterKey.runError: runError?.localizedDescription ?? "none"
                        ])
                        throw error
                    }
                }

                try await withTaskCancellationHandler {
                    logger.info("Start virtual machine", parameters: [
                        LogParameterKey.vmName: virtualMachine.name,
                        LogParameterKey.jobId: "\(pendingJob.id)",
                        LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)",
                        LogParameterKey.uuid: uuid.uuidString
                    ])
                    do {
                        try await virtualMachine.start(netBridgedAdapter: pendingJob.netBridgedAdapter, isHeadless: pendingJob.isHeadless)
                        logger.info("Did stop virtual machine", parameters: [
                            LogParameterKey.vmName: virtualMachine.name,
                            LogParameterKey.jobId: "\(pendingJob.id)",
                            LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)",
                            LogParameterKey.uuid: uuid.uuidString
                        ])
                        try await delete()
                    } catch {
                        logger.error("Virtual machine stopped with error", parameters: [
                            LogParameterKey.vmName: virtualMachine.name,
                            LogParameterKey.jobId: "\(pendingJob.id)",
                            LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)",
                            LogParameterKey.uuid: uuid.uuidString,
                            LogParameterKey.error: error.localizedDescription
                        ])
                        try await delete(error: error)
                        throw error
                    }
                } onCancel: {
                    Task.detached(priority: .high) {
                        logger.info("Cancel virtual machine", parameters: [
                            LogParameterKey.vmName: virtualMachine.name,
                            LogParameterKey.jobId: "\(pendingJob.id)",
                            LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)",
                            LogParameterKey.uuid: uuid.uuidString
                        ])
                        do {
                            try await virtualMachine.delete()
                        } catch {
                            logger.info("Could not delete virtual machine", parameters: [
                                LogParameterKey.vmName: virtualMachine.name,
                                LogParameterKey.jobId: "\(pendingJob.id)",
                                LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)",
                                LogParameterKey.uuid: uuid.uuidString,
                                LogParameterKey.error: error.localizedDescription
                            ])
                            throw error
                        }
                        await self?.remove(uuid: uuid)
                    }
                }

                await self?.remove(uuid: uuid)
            } catch {
                logger.error("Job execution failed", parameters: [
                    LogParameterKey.jobId: "\(pendingJob.id)",
                    LogParameterKey.workflowJobId: "\(pendingJob.workflowJob.id)",
                    LogParameterKey.uuid: uuid.uuidString,
                    LogParameterKey.error: error.localizedDescription
                ])
                await self?.remove(uuid: uuid)
            }
        }

        activeJobs[uuid]?.task.cancel()
        activeJobs[uuid] = .init(labels: pendingJob.workflowJob.labels, task: task, cpu: pendingJob.cpu, memory: pendingJob.memory)
    }

    func remove(uuid: UUID) {
        activeJobs.removeValue(forKey: uuid)
        if activeJobs.count < numberOfMachines, let pendingJob = pendingJobs.first(where: { !$0.value.didStart })?.value {
            start(pendingJob: pendingJob)
        }
        Task {
           await activeJobEnded()
        }
    }

    func activeJobEnded() async {
        guard let routerUrl = routerUrl.flatMap({ URL(string: $0) }) else { return }
        var request = URLRequest(url: routerUrl.appending(path: "runner"))
        request.httpMethod = "POST"
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            logger.error("Error calling router", parameters: [
                LogParameterKey.routerUrl: routerUrl.absoluteString,
                LogParameterKey.error: error.localizedDescription
            ])
        }
    }
}
