import Foundation
import LoggingDomain
import WebServer

struct ActiveJob {
    let labels: Set<String>
    let task: Task<(), Never>
    let cpu: Int?
    let memory: Int?
}

actor JobHandler {
    private var numberOfMachines = 1
    private var activeJobs = [UUID: ActiveJob]()
    private var inProgressJobs = [Int: PendingJob]()
    private var pendingJobs = [Int: PendingJob]()
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

    init(routerUrl: String?, virtualMachineProvider: VirtualMachineProvider, logger: Logger) {
        self.routerUrl = routerUrl
        self.virtualMachineProvider = virtualMachineProvider
        self.logger = logger

        Task {
           await activeJobEnded()
        }
    }

    func set(numberOfMachines: Int) {
        self.numberOfMachines = numberOfMachines
    }

    func handle(pendingJob: PendingJob) -> Bool {
        switch pendingJob.action {
        case .routerStart:
            logger.info("Router start job added: \(pendingJob.id)")

            if activeJobs.count < numberOfMachines {
                start(pendingJob: pendingJob)
            } else {
                return false
            }
        case .waiting:
            logger.info("Waiting job added: \(pendingJob.id)")
        case .queued:
            logger.info("Pending job added: \(pendingJob.id)")
            pendingJobs[pendingJob.id] = pendingJob

            if activeJobs.count < numberOfMachines {
                start(pendingJob: pendingJob)
            }
        case .inProgress:
            logger.info("In progress job added: \(pendingJob.id)")
            let oldJob = pendingJobs.removeValue(forKey: pendingJob.id)
            if let oldJob, !oldJob.didStart {
                pendingJobs.values.first { existingJob in
                    existingJob.workflowJob.labels == pendingJob.workflowJob.labels && existingJob.didStart
                }?.didStart = false
            }
            inProgressJobs[pendingJob.id] = pendingJob
        case .completed:
            logger.info("Completed job added: \(pendingJob.id)")
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
                activeJobs.forEach { _, activeJob in
                    guard activeJob.labels == pendingJob.workflowJob.labels else {
                        return
                    }
                    activeJob.task.cancel()
                }
            } else if otherInProgress <= running {
                pendingJobs.values.first { existingJob in
                    existingJob.workflowJob.labels == pendingJob.workflowJob.labels && !existingJob.didStart
                }?.didStart = true
            }
        case .unknown:
            logger.info("Unknown job added: \(pendingJob.id)")
        }
        return true
    }

    func cancelAll() {
        for (_, job) in activeJobs {
            job.task.cancel()
        }
    }

    private func start(pendingJob: PendingJob) {
        logger.info("Starting job: \(pendingJob.workflowJob.id)")
        pendingJob.didStart = true
        let runnerLabels = pendingJob.workflowJob.labels.joined(separator: ",")
        let uuid = UUID()
        let task = Task { [weak self, logger, virtualMachineProvider] in
            do {
                logger.info("Creating virtual with image \(pendingJob.imageName)")
                let virtualMachine = try await virtualMachineProvider.createVirtualMachine(
                    imageName: pendingJob.imageName,
                    name: "tartelet-temp-\(uuid.uuidString)",
                    runnerLabels: runnerLabels,
                    isInsecure: pendingJob.isInsecure,
                    cpu: pendingJob.cpu,
                    memory: pendingJob.memory
                )

                func delete() async throws {
                    do {
                        try await virtualMachine.delete()
                        logger.info("Did delete virtual machine named \(virtualMachine.name)")
                    } catch {
                        logger.info("Could not delete virtual machine named \(virtualMachine.name)")
                        throw error
                    }
                }

                try await withTaskCancellationHandler {
                    logger.info("Start virtual machine named \(virtualMachine.name)")
                    do {
                        try await virtualMachine.start(netBridgedAdapter: pendingJob.netBridgedAdapter, isHeadless: pendingJob.isHeadless)
                        logger.info("Did stop virtual machine named \(virtualMachine.name)")
                        try await delete()
                    } catch {
                        logger.info("Virtual machine named \(virtualMachine.name) stopped with message: " + error.localizedDescription)
                        try await delete()
                        throw error
                    }
                } onCancel: {
                    Task.detached(priority: .high) {
                        logger.info("Cancel virtual machine named \(virtualMachine.name)")
                        do {
                            try await virtualMachine.delete()
                        } catch {
                            logger.info("Could not delete virtual machine named \(virtualMachine.name): " + error.localizedDescription)
                            throw error
                        }
                    }
                }

                await self?.remove(uuid: uuid)
            } catch {
                logger.error(error.localizedDescription)
                await self?.remove(uuid: uuid)
            }
        }

        activeJobs[uuid]?.task.cancel()
        activeJobs[uuid] = .init(labels: pendingJob.workflowJob.labels, task: task, cpu: pendingJob.cpu, memory: pendingJob.memory)
    }

    private func remove(uuid: UUID) {
        activeJobs.removeValue(forKey: uuid)
        if activeJobs.count < numberOfMachines, let pendingJob = pendingJobs.first(where: { !$0.value.didStart })?.value {
            start(pendingJob: pendingJob)
        }
        Task {
           await activeJobEnded()
        }
    }

    private func activeJobEnded() async {
        guard let routerUrl = routerUrl.flatMap({ URL(string: $0) }) else { return }
        var request = URLRequest(url: routerUrl.appending(path: "runner"))
        request.httpMethod = "POST"
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            logger.error("Error calling router: \(error)")
        }
    }
}
