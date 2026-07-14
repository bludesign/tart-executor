import Foundation
import LoggingDomain
import TartCommon

actor RouterJobHandler {
    struct StatusCounts {
        let pendingJobs: Int
        let pendingJobsUnsent: Int
        let pendingJobsQueued: Int
        let availableVirtualMachines: Int
        let availableHosts: Int
    }

    private enum JobError: Error {
        case errorSending
    }

    private enum Constants {
        // How long a host must continuously report fewer virtual machines than the number of
        // jobs attributed to it before those jobs are considered lost and requeued. Must be
        // longer than the delay between a virtual machine shutting down and GitHub delivering
        // the completed webhook for the job it ran.
        static let lostJobRequeueInterval: TimeInterval = 15
    }

    private nonisolated let logger: Logger
    private let decoder = JSONDecoder()
    private var jobs = [Int: RouterPendingJob]()
    private var hosts: [TartHost]
    private var isUpdatingStatus = false
    private var needsAnotherUpdate = false
    private var hostDeficitSince = [ObjectIdentifier: Date]()

    var pendingJobs: Int {
        jobs.count
    }

    var pendingJobsUnsent: Int {
        jobs.reduce(0) { $0 + ($1.value.sentToHost != nil ? 0 : 1) }
    }

    var pendingJobsQueued: Int {
        jobs.reduce(0) { $0 + ($1.value.workflowJob.action == .queued ? 1 : 0) }
    }

    var availableVirtualMachines: Int {
        hosts.reduce(0) { $0 + (($1.lastStatus?.virtualMachineLimit ?? 0) - ($1.lastStatus?.activeVirtualMachines ?? 0)) }
    }

    var availableHosts: Int {
        hosts.reduce(0) { $0 + ($1.lastStatus != nil ? 1 : 0) }
    }

    init(hosts: [TartHost], logger: Logger) {
        self.hosts = hosts
        self.logger = logger
    }

    func handleJob(job newJob: RouterPendingJob) async {
        logger.info("Job Router Handle", job: newJob)

        await updateStatus(shouldSendJobs: false)

        let job: RouterPendingJob
        switch newJob.workflowJob.action {
        case .queued, .inProgress:
            if let existingJob = jobs[newJob.id] {
                job = existingJob
            } else {
                jobs[newJob.id] = newJob
                job = newJob
            }
            // A redelivered or out-of-order "queued" webhook must not regress a job that
            // GitHub already reported as in progress, or the job would be sent out again.
            if !(job.workflowJob.action == .inProgress && newJob.workflowJob.action == .queued) {
                job.workflowJob = newJob.workflowJob
            }
        case .completed:
            let removedJob = jobs.removeValue(forKey: newJob.id)
            if let removedJob, removedJob.workflowJob.action == .inProgress {
                // The job ran to completion. If it was never attributed to a host it ran on a
                // virtual machine that is still attributed to another queued job; take over
                // that attribution so the queued job is sent out again.
                adoptHostAttribution(for: removedJob)
            }
            let remainingJobs = jobs.values.filter { existingJob in
                existingJob.workflowJob.labels == newJob.workflowJob.labels
            }.count
            if remainingJobs == 0 {
                // No jobs are left with these labels, so any idle virtual machine waiting for
                // work with these labels will never receive a job. Cancel them on all hosts.
                // This intentionally also runs for jobs this router doesn't know, so idle
                // machines left over from before a router restart are still cleaned up.
                await cancelJobsWithLabels(newJob.workflowJob.labels)
            }
            await updateStatus()
            return
        case .waiting, .unknown, .routerStart:
            return
        }

        if job.workflowJob.action == .inProgress {
            adoptHostAttribution(for: job)
        }
        await updateStatus()
    }

    func cancelJobsWithLabels(_ labels: Set<String>) async {
        await withTaskGroup(of: Void.self) { [weak self] group in
            guard let self else { return }
            await hosts.forEach { [weak self] host in
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        try await Self.cancelJobsByLabels(host: host, labels: labels, logger: logger)
                    } catch {
                        logger.error("Executor API Job Cancel With Labels Error", host: host, labels: labels, error: error)
                    }
                }
            }
        }
    }

    func updateStatus(shouldSendJobs: Bool = true) async {
        // The timer, executor callbacks, and webhooks can all trigger an update while one is
        // already running. Re-entrant runs would send the same job to multiple hosts, so
        // coalesce concurrent calls into a follow-up pass of the running update instead.
        guard !isUpdatingStatus else {
            if shouldSendJobs {
                needsAnotherUpdate = true
            }
            return
        }
        isUpdatingStatus = true
        defer {
            isUpdatingStatus = false
        }
        var shouldSend = shouldSendJobs
        repeat {
            needsAnotherUpdate = false
            await pollHostStatuses()
            requeueLostJobs()
            if shouldSend {
                await sendQueuedJobs()
            }
            shouldSend = true
        } while needsAnotherUpdate
    }

    // MARK: - Management API support

    func jobsSnapshot() -> [RouterJobDTO] {
        jobs.values
            .map { routerJobDTO(for: $0) }
            .sorted { $0.id < $1.id }
    }

    func job(id: Int) -> RouterJobDTO? {
        jobs[id].map { routerJobDTO(for: $0) }
    }

    func hostsSnapshot() -> [RouterHostDTO] {
        hosts.map { host in
            RouterHostDTO(
                hostname: host.hostname,
                url: host.url.absoluteString,
                priority: host.priority,
                cpuLimit: host.cpuLimit,
                memoryLimit: host.memoryLimit,
                reachable: host.lastStatus != nil,
                lastStatus: host.lastStatus
            )
        }
    }

    func host(named hostname: String) -> RouterHostDTO? {
        hostsSnapshot().first { $0.hostname == hostname }
    }

    func statusCounts() -> StatusCounts {
        StatusCounts(
            pendingJobs: pendingJobs,
            pendingJobsUnsent: pendingJobsUnsent,
            pendingJobsQueued: pendingJobsQueued,
            availableVirtualMachines: availableVirtualMachines,
            availableHosts: availableHosts
        )
    }

    /// Removes a job from the router queue and, if it was already dispatched, cancels it on the
    /// host it was sent to (by label set). Returns whether a job with that id existed.
    func cancelJob(id: Int) async -> Bool {
        guard let job = jobs.removeValue(forKey: id) else {
            return false
        }
        logger.info("Job Router Cancelled By Id", job: job)
        if let host = job.sentToHost {
            try? await Self.cancelJobsByLabels(host: host, labels: job.workflowJob.labels, logger: logger)
        }
        return true
    }

    private func routerJobDTO(for job: RouterPendingJob) -> RouterJobDTO {
        RouterJobDTO(
            id: job.id,
            action: job.workflowJob.action,
            labels: job.workflowJob.labels.sorted(),
            sentToHost: job.sentToHost?.hostname,
            receivedAt: job.receivedAt,
            sentAt: job.sentAt
        )
    }
}

private extension RouterJobHandler {
    static func sendJob(host: TartHost, job: RouterPendingJob, logger: Logger) async throws {
        logger.info("Executor Send Job", job: job, host: host)
        var hostRequest = URLRequest(url: host.url.appending(path: "/router"))
        hostRequest.httpMethod = "POST"
        hostRequest.httpBody = job.bodyData
        job.headers.forEach { header, value in
            hostRequest.setValue(value, forHTTPHeaderField: header.rawValue)
        }
        let (_, response) = try await URLSession.shared.data(for: hostRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw JobError.errorSending
        }
    }

    static func cancelJobsByLabels(host: TartHost, labels: Set<String>, logger: Logger) async throws {
        var hostRequest = URLRequest(url: host.url.appending(path: "/cancel"))
        hostRequest.httpMethod = "POST"
        hostRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let cancelRequest = CancelJobsRequest(labels: labels)
        let encoder = JSONEncoder()
        hostRequest.httpBody = try encoder.encode(cancelRequest)

        let (_, response) = try await URLSession.shared.data(for: hostRequest)
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            throw JobError.errorSending
        }
    }

    // GitHub assigns jobs to any runner with matching labels, so a job can start on a virtual
    // machine that was created for a different queued job. When a job starts (or completes)
    // without ever having been attributed to a host, take over the attribution from a job that
    // is still queued, so that job is sent out again to replace the machine it lost.
    func adoptHostAttribution(for job: RouterPendingJob) {
        guard job.sentToHost == nil else { return }
        guard let donorJob = jobs.values.first(where: { existingJob in
            existingJob.id != job.workflowJob.id &&
            existingJob.workflowJob.labels == job.workflowJob.labels &&
            existingJob.workflowJob.action == .queued &&
            existingJob.sentToHost != nil
        }) else {
            logger.error("Job Router No Existing Job Found", job: job)
            return
        }
        job.sentToHost = donorJob.sentToHost
        donorJob.sentToHost = nil
    }

    func pollHostStatuses() async {
        await withTaskGroup(of: Void.self) { [weak self] group in
            guard let self else { return }
            await hosts.forEach { [weak self] host in
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        let url = host.url.appending(path: "/status")
                        let (data, _) = try await URLSession.shared.data(from: url)
                        let status = try decoder.decode(TartHostStatus.self, from: data)
                        host.lastStatus = status
                    } catch {
                        host.lastStatus = nil
                        logger.error("Executor API Get Status Error", host: host, error: error)
                    }
                }
            }
        }
    }

    // A job stays attributed to a host even if the host lost it because the virtual machine
    // could not be created, or the executor crashed or restarted. Executors report how many
    // machines they are actually running; when a host keeps reporting fewer machines than the
    // number of jobs attributed to it, the difference will never run, so clear the attribution
    // of that many queued jobs to have them sent out again. The deficit must persist for a
    // while before jobs are requeued because a completed job's webhook typically arrives a few
    // seconds after its machine already shut down, which looks like a deficit as well.
    func requeueLostJobs() {
        let now = Date()
        for host in hosts {
            let hostKey = ObjectIdentifier(host)
            guard let lastStatus = host.lastStatus else {
                hostDeficitSince[hostKey] = nil
                continue
            }
            let attributedJobs = jobs.values.filter { $0.sentToHost === host }
            let lostJobs = attributedJobs.count - lastStatus.activeVirtualMachines
            guard lostJobs > 0 else {
                hostDeficitSince[hostKey] = nil
                continue
            }
            guard let deficitSince = hostDeficitSince[hostKey] else {
                hostDeficitSince[hostKey] = now
                continue
            }
            guard now.timeIntervalSince(deficitSince) >= Constants.lostJobRequeueInterval else { continue }
            hostDeficitSince[hostKey] = nil
            // Only queued jobs can be requeued. An in-progress job whose machine died is
            // GitHub's to fail; its completed webhook will remove it.
            let queuedJobs = attributedJobs.filter { $0.workflowJob.action == .queued }
            for job in queuedJobs.prefix(lostJobs) {
                logger.error("Job Router Lost By Host", job: job, host: host)
                job.sentToHost = nil
            }
        }
    }

    func sendQueuedJobs() async {
        // Iterate over a snapshot: every send suspends this actor and webhooks can mutate
        // `jobs` in the meantime, so each job is re-checked right before it is sent.
        for job in jobs.values {
            guard jobs[job.id] === job, job.sentToHost == nil, job.workflowJob.action == .queued else { continue }
            await sendQueuedJob(job)
        }
    }

    func sendQueuedJob(_ job: RouterPendingJob) async {
        var foundEligibleHost = false
        for host in hosts {
            // The job may have completed or been attributed to a host while a previous send
            // attempt was awaited.
            guard jobs[job.id] === job, job.sentToHost == nil, job.workflowJob.action == .queued else { return }
            guard let lastStatus = host.lastStatus, job.hostCanRun(host) else { continue }
            foundEligibleHost = true
            guard lastStatus.activeVirtualMachines < lastStatus.virtualMachineLimit else { continue }
            do {
                try await Self.sendJob(host: host, job: job, logger: logger)
            } catch {
                logger.error("Executor API Send Job Error", job: job, host: host, error: error)
                continue
            }
            // The virtual machine now exists on the host no matter what happened to the job
            // while the send was in flight.
            host.lastStatus?.activeVirtualMachines += 1
            if jobs[job.id] === job, job.sentToHost == nil, job.workflowJob.action == .queued {
                job.sentToHost = host
            } else if jobs[job.id] !== job {
                // The job finished while the send was in flight, so the label cancel that runs
                // on completion has already passed and the machine that was just created would
                // idle forever. Cancel it on the host it was sent to.
                logger.error("Job Router Job Finished During Send", job: job, host: host)
                try? await Self.cancelJobsByLabels(host: host, labels: job.workflowJob.labels, logger: logger)
            } else {
                // The job was attributed to another host or started while the send was in
                // flight. The machine will pick up other queued work with these labels or be
                // cancelled once the last job with them completes.
                logger.error("Job Router Job Changed During Send", job: job, host: host)
            }
            return
        }
        if !foundEligibleHost {
            logger.error("Job Router No Host Can Handle Job CPU/Memory", job: job)
        }
    }
}
