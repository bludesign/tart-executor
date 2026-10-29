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

    enum Constants {
        // How long a host must continuously report fewer virtual machines than the number of
        // jobs attributed to it before those jobs are considered lost and requeued. Must be
        // longer than the delay between a virtual machine shutting down and GitHub delivering
        // the completed webhook for the job it ran.
        static let lostJobRequeueInterval: TimeInterval = 15
    }

    // Module-internal rather than private so `RouterJobHandler+Dispatch` can reach them; the
    // actor itself is internal, so this widens nothing outside RouterApp.
    nonisolated let logger: Logger
    private let decoder = JSONDecoder()
    var jobs = [Int: RouterPendingJob]()
    let reconciler: (any RouterGitHubReconciling)?
    let runnerLabels: Set<String>
    let session: URLSession
    var completedJobs = [Int: Date]()
    var reconciledAt = [Int: Date]()
    var isReconciling = false
    var recoveryAttemptedAt = [Int: Date]()
    var reconciledCompletedJobs = Set<Int>()
    var hosts: [TartHost]
    private var isUpdatingStatus = false
    private var needsAnotherUpdate = false
    var hostDeficitSince = [ObjectIdentifier: Date]()

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

    init(hosts: [TartHost], logger: Logger, reconciler: (any RouterGitHubReconciling)? = nil, runnerLabels: Set<String> = [], session: URLSession = .shared) {
        self.hosts = hosts
        self.logger = logger
        self.reconciler = reconciler
        self.runnerLabels = runnerLabels
        self.session = session
    }

    func handleJob(job newJob: RouterPendingJob) async {
        logger.info("Job Router Handle", job: newJob)

        if newJob.workflowJob.action == .completed {
            rememberCompletedJob(id: newJob.id)
        }

        await updateStatus(shouldSendJobs: false)

        let job: RouterPendingJob
        switch newJob.workflowJob.action {
        case .queued, .inProgress:
            guard completedJobs[newJob.id] == nil else {
                logger.info("Job Router Ignored Event For Completed Job", job: newJob)
                return
            }
            if let existingJob = jobs[newJob.id] {
                job = existingJob
                if let repository = newJob.repository {
                    job.repository = repository
                }
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
            reconciledAt[newJob.id] = nil
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
                        try await Self.cancelJobsByLabels(host: host, labels: labels, logger: logger, session: session)
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
        rememberCompletedJob(id: id)
        reconciledAt[id] = nil
        logger.info("Job Router Cancelled By Id", job: job)
        if let host = job.sentToHost {
            try? await Self.cancelJobsByLabels(host: host, labels: job.workflowJob.labels, logger: logger, session: session)
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
            sentAt: job.sentAt,
            repository: job.repository
        )
    }
}

extension RouterJobHandler {
    static func sendJob(host: TartHost, job: RouterPendingJob, logger: Logger, session: URLSession) async throws {
        logger.info("Executor Send Job", job: job, host: host)
        var hostRequest = URLRequest(url: host.url.appending(path: "/router"))
        hostRequest.httpMethod = "POST"
        hostRequest.httpBody = job.bodyData
        job.headers.forEach { header, value in
            hostRequest.setValue(value, forHTTPHeaderField: header.rawValue)
        }
        let (_, response) = try await session.data(for: hostRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw JobError.errorSending
        }
    }

    static func cancelJobsByLabels(host: TartHost, labels: Set<String>, logger: Logger, session: URLSession) async throws {
        var hostRequest = URLRequest(url: host.url.appending(path: "/cancel"))
        hostRequest.httpMethod = "POST"
        hostRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let cancelRequest = CancelJobsRequest(labels: labels)
        let encoder = JSONEncoder()
        hostRequest.httpBody = try encoder.encode(cancelRequest)

        let (_, response) = try await session.data(for: hostRequest)
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

    private func pollHostStatuses() async {
        await withTaskGroup(of: Void.self) { [weak self] group in
            guard let self else { return }
            await hosts.forEach { [weak self] host in
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        let url = host.url.appending(path: "/status")
                        let (data, _) = try await session.data(from: url)
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

}
