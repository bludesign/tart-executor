import Foundation
import LoggingDomain
import TartCommon
import VirtualMachineDomain

struct ActiveJob {
    let jobId: Int
    let labels: Set<String>
    let task: Task<(), Never>
    let cpu: Int?
    let memory: Int?
    let vmName: String
    let startedAt: Date
    let imageName: String
}

actor ExecutorJobHandler {
    // Module-internal rather than private so the dispatch and recovery extensions can reach them; the
    // actor itself is internal, so this widens nothing outside ExecutorApp.
    let numberOfMachines: Int
    let cpuLimit: Int
    let totalMemory: Int
    var activeJobs = [UUID: ActiveJob]()
    var inProgressJobs = [Int: ExecutorPendingJob]()
    var pendingJobs = [Int: ExecutorPendingJob]()
    var metadataWaitingRefreshCursor = 0
    var metadataRefreshCursor = 0
    var jobContexts = [Int: GitHubJobContext]()
    var createdJobIDs = [String: Int]()
    var assignedJobs = [String: GitHubJobContext]()
    var pendingJobRetries = [Int: PendingJobRetry]()
    let waitForPendingJobRetry: @Sendable () async throws -> Void
    nonisolated private let routerUrl: String?
    nonisolated let virtualMachineProvider: VirtualMachineProvider
    nonisolated let logger: Logger

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

    init(
        routerUrl: String?,
        virtualMachineProvider: VirtualMachineProvider,
        logger: Logger,
        numberOfMachines: Int,
        cpuLimit: Int,
        totalMemory: Int,
        waitForPendingJobRetry: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(30))
        }
    ) {
        self.routerUrl = routerUrl
        self.virtualMachineProvider = virtualMachineProvider
        self.logger = logger
        self.numberOfMachines = numberOfMachines
        self.cpuLimit = cpuLimit
        self.totalMemory = totalMemory
        self.waitForPendingJobRetry = waitForPendingJobRetry

        Task {
           await activeJobEnded()
        }
    }

    func handle(pendingJob: ExecutorPendingJob) -> Bool {
        defer { pruneContexts() }
        if let context = pendingJob.workflowJob.github {
            rememberContext(context)
            observeJob(context)
        }
        switch pendingJob.action {
        case .routerStart:
            return handleRouterStart(pendingJob: pendingJob)
        case .waiting:
            logger.info("Job Handle Waiting", pendingJob: pendingJob)
        case .queued:
            handleQueued(pendingJob: pendingJob)
        case .inProgress:
            handleInProgress(pendingJob: pendingJob)
        case .completed:
            handleCompleted(pendingJob: pendingJob)
        case .unknown:
            logger.info("Job Unknown Added", pendingJob: pendingJob)
        }
        return true
    }

    func cancelAll() {
        defer { pruneContexts() }
        for retry in pendingJobRetries.values {
            retry.task.cancel()
        }
        pendingJobRetries.removeAll()
        pendingJobs.removeAll()
        for (_, job) in activeJobs {
            job.task.cancel()
        }
    }

    @discardableResult
    func cancelJobsByLabels(_ labels: Set<String>) -> Int {
        defer { pruneContexts() }
        let pendingIds = pendingJobs.values.filter { $0.workflowJob.labels == labels }.map(\.id)
        for id in pendingIds {
            cancelPendingJobRetry(id: id)
            pendingJobs.removeValue(forKey: id)
        }
        var cancelledIds = Set(pendingIds)
        activeJobs.forEach { _, activeJob in
            guard activeJob.labels == labels else {
                return
            }
            cancelledIds.insert(activeJob.jobId)
            activeJob.task.cancel()
        }
        logger.info("Jobs Cancalled With Labels", [
            LogParameterKey.cancelledCount: "\(cancelledIds.count)",
            LogParameterKey.labels: labels.joined(separator: ",")
        ])
        return cancelledIds.count
    }

    /// Snapshot of every job currently tracked (queued, in-progress, or with a lingering VM),
    /// one entry per job id, most-advanced state winning.
    func jobsSnapshot() -> [ExecutorJobDTO] {
        var vmByJobId = [Int: (uuid: UUID, job: ActiveJob)]()
        for (uuid, job) in activeJobs where vmByJobId[job.jobId] == nil {
            vmByJobId[job.jobId] = (uuid, job)
        }

        func makeDTO(id: Int, pending: ExecutorPendingJob?, state: ExecutorJobState) -> ExecutorJobDTO {
            let vm = vmByJobId[id]
            let labels: Set<String>
            if let pendingLabels = pending?.workflowJob.labels {
                labels = pendingLabels
            } else if let vmLabels = vm?.job.labels {
                labels = vmLabels
            } else {
                labels = []
            }
            return ExecutorJobDTO(
                id: id,
                action: pending?.workflowJob.action ?? .unknown,
                state: state,
                labels: labels.sorted(),
                didStart: pending?.didStart ?? true,
                cpu: pending?.cpu ?? vm?.job.cpu,
                memory: pending?.memory ?? vm?.job.memory,
                imageName: pending?.imageName ?? vm?.job.imageName,
                vmName: vm?.job.vmName,
                vmUUID: vm?.uuid.uuidString,
                queuedAt: pending?.queuedAt,
                startedAt: vm?.job.startedAt,
                github: jobContexts[id] ?? pending?.workflowJob.github
            )
        }

        var byId = [Int: ExecutorJobDTO]()
        for (id, job) in inProgressJobs {
            byId[id] = makeDTO(id: id, pending: job, state: .inProgress)
        }
        for (id, job) in pendingJobs where byId[id] == nil {
            byId[id] = makeDTO(id: id, pending: job, state: .pending)
        }
        for (id, _) in vmByJobId where byId[id] == nil {
            byId[id] = makeDTO(id: id, pending: nil, state: .active)
        }
        return byId.values.sorted { $0.id < $1.id }
    }

    func job(id: Int) -> ExecutorJobDTO? {
        jobsSnapshot().first { $0.id == id }
    }

    /// Cancels a single job by GitHub id: cancels any running VM task and drops it from the
    /// pending/in-progress queues. Returns whether anything was cancelled.
    @discardableResult
    func cancel(jobId: Int) -> Bool {
        defer { pruneContexts() }
        cancelPendingJobRetry(id: jobId)
        var cancelled = false
        for (_, job) in activeJobs where job.jobId == jobId {
            job.task.cancel()
            cancelled = true
        }
        if pendingJobs.removeValue(forKey: jobId) != nil {
            cancelled = true
        }
        if inProgressJobs.removeValue(forKey: jobId) != nil {
            cancelled = true
        }
        if cancelled {
            logger.info("Job Cancelled By Id", [LogParameterKey.jobId: "\(jobId)"])
        }
        return cancelled
    }
}

extension ExecutorJobHandler {
    func handleRouterStart(pendingJob: ExecutorPendingJob) -> Bool {
        let isAlreadyRunning = activeJobs.values.contains { $0.jobId == pendingJob.id }
        if isAlreadyRunning {
            // The router sent a job this executor already has a virtual machine for. Report
            // success so the router does not send it elsewhere as well.
            return true
        }
        guard hasVirtualMachineSlot else {
            logVirtualMachineLimitReached(pendingJob)
            return false
        }
        guard hasResources(for: pendingJob) else {
            logResourceCapacityReached(pendingJob)
            return false
        }
        logger.info("Job Handle Router Started", pendingJob: pendingJob, [
            LogParameterKey.willStart: "true",
            LogParameterKey.activeJobs: "\(activeJobs.count)",
            LogParameterKey.maxMachines: "\(numberOfMachines)"
        ])
        start(pendingJob: pendingJob)
        return true
    }

    func handleQueued(pendingJob: ExecutorPendingJob) {
        guard pendingJobs[pendingJob.id] == nil, inProgressJobs[pendingJob.id] == nil else {
            // Redelivered webhook for a job that is already tracked. Starting it again would
            // create a second virtual machine for the same job.
            logger.info("Job Handle Pending Duplicate Skipped", pendingJob: pendingJob)
            return
        }
        logger.info("Job Handle Pending", pendingJob: pendingJob)
        pendingJobs[pendingJob.id] = pendingJob

        startIfCapacityAllows(pendingJob)
    }

    func handleInProgress(pendingJob: ExecutorPendingJob) {
        cancelPendingJobRetry(id: pendingJob.id)
        logger.info("Job Handle In Progress", pendingJob: pendingJob)
        let oldJob = pendingJobs.removeValue(forKey: pendingJob.id)
        if let oldJob, !oldJob.didStart {
            // The job started without a machine of its own, so it is running on a machine
            // that was started for another queued job with the same labels. That job lost its
            // machine; mark it unstarted and start a machine for it if there is capacity.
            pendingJobs.values.first { existingJob in
                existingJob.workflowJob.labels == pendingJob.workflowJob.labels && existingJob.didStart
            }?.didStart = false
            startNextPendingJob()
        }
        inProgressJobs[pendingJob.id] = pendingJob
    }

    func handleCompleted(pendingJob: ExecutorPendingJob) {
        cancelPendingJobRetry(id: pendingJob.id)
        logger.info("Job Handle Completed", pendingJob: pendingJob)
        let removedInProgressJob = inProgressJobs.removeValue(forKey: pendingJob.id)
        let removedPendingJob = pendingJobs.removeValue(forKey: pendingJob.id)
        pruneContexts()
        guard removedInProgressJob != nil || removedPendingJob != nil else {
            return
        }
        let labels = pendingJob.workflowJob.labels
        let otherPending = pendingJobs.values.filter { existingJob in
            existingJob.workflowJob.labels == labels
        }.count
        let otherInProgress = inProgressJobs.values.filter { existingJob in
            existingJob.workflowJob.labels == labels
        }.count
        if otherPending == 0, otherInProgress == 0 {
            // No jobs are left with these labels, so any idle machine waiting for work with
            // these labels will never receive a job.
            scheduleIdleMachineCancellation(labels: labels)
        } else if removedPendingJob?.didStart == true {
            // The job was cancelled while queued but its machine is already up and will be
            // picked by another queued job with the same labels. Hand the machine over so that
            // job does not start a second one.
            pendingJobs.values.first { existingJob in
                existingJob.workflowJob.labels == labels && !existingJob.didStart
            }?.didStart = true
        }
    }

    // Cancelling immediately would also hit the machine that ran the job while it is still
    // shutting itself down, so wait before checking again whether machines with these labels
    // are still needed.
    func scheduleIdleMachineCancellation(labels: Set<String>) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ExecutorConstants.idleMachineCancellationDelay))
            await self?.cancelIdleMachines(labels: labels)
        }
    }

    func cancelIdleMachines(labels: Set<String>) {
        let jobsWithLabelsExist = pendingJobs.values.contains { $0.workflowJob.labels == labels }
            || inProgressJobs.values.contains { $0.workflowJob.labels == labels }
        guard !jobsWithLabelsExist else { return }
        cancelJobsByLabels(labels)
    }

    func remove(uuid: UUID) {
        // Cancellation cleanup and the VM task can both finish. Only the first removal may
        // release capacity or schedule a replacement.
        guard let activeJob = activeJobs.removeValue(forKey: uuid) else { return }
        pruneContexts()
        if !activeJob.task.isCancelled, let pendingJob = pendingJobs[activeJob.jobId],
           inProgressJobs[activeJob.jobId] == nil {
            schedulePendingJobRetry(pendingJob)
        }
        startNextPendingJob()
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
            logger.error("Router API Call Error", error: error, [
                LogParameterKey.routerUrl: routerUrl.absoluteString
            ])
        }
    }
}
