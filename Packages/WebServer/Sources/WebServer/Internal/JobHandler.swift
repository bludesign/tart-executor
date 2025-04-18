import Foundation
import LoggingDomain

actor JobHandler {
    private nonisolated let logger: Logger
    private let decoder = JSONDecoder()
    private var jobs = [Int: PendingJob]()
    private var hosts: [TartHost]

    var pendingJobs: Int {
        jobs.count
    }

    var pendingJobsUnsent: Int {
        jobs.reduce(0) { $0 + ($1.value.sentToHost != nil ? 0 : 1) }
    }

    init(hosts: [TartHost], logger: Logger) {
        self.hosts = hosts
        self.logger = logger
    }

    static func sendJob(host: TartHost, job: PendingJob, logger: Logger) async throws {
        logger.info("Sending job: \(job.workflowJob.id) to host: \(host.hostname)")
        var hostRequest = URLRequest(url: host.url.appending(path: "/router"))
        hostRequest.httpMethod = "POST"
        hostRequest.httpBody = job.bodyData
        job.headers.forEach { header, value in
            hostRequest.setValue(value, forHTTPHeaderField: header.rawValue)
        }
        _ = try await URLSession.shared.data(for: hostRequest)
        job.sentToHost = host
    }

    func handleJob(job newJob: PendingJob) async {
        await updateStatus(sendJobs: false)

        let job: PendingJob
        switch newJob.workflowJob.action {
        case .queued, .inProgress:
            job = jobs[newJob.id, default: newJob]
            job.workflowJob = newJob.workflowJob
        case .completed:
            jobs.removeValue(forKey: newJob.id)
            return
        case .waiting, .unknown, .routerStart:
            return
        }
        let workflowJob = job.workflowJob

        do {
            switch workflowJob.action {
            case .queued:
                try await handleQueuedJob(job: job)
            case .inProgress:
                if job.sentToHost == nil {
                    guard let existingJob = jobs.values.first(where: { existingJob in
                        existingJob.id != workflowJob.id && existingJob.workflowJob.labels == workflowJob.labels && existingJob.workflowJob.action == .queued && existingJob.sentToHost != nil
                    }) else {
                        logger.error("Error no existing job found: \(job)")
                        return
                    }
                    job.sentToHost = existingJob.sentToHost
                    existingJob.sentToHost = nil
                }
            case .completed, .waiting, .unknown, .routerStart:
                break
            }
        } catch {
            logger.error("Error handling job: \(job)")
        }
    }

    @discardableResult
    func handleQueuedJob(job: PendingJob) async throws -> Bool {
        var lowestCapacityHost: (capacity: Int, host: TartHost)?
        for host in hosts {
            guard let lastStatus = host.lastStatus, job.hostCanRun(host) else { continue }
            let capacity = lastStatus.virtualMachineLimit - lastStatus.totalJobs
            let hasCapacity = lastStatus.activeVirtualMachines < lastStatus.virtualMachineLimit
            if let currentLowestCapacity = lowestCapacityHost {
                if capacity > currentLowestCapacity.capacity {
                    lowestCapacityHost = (capacity, host)
                }
            } else {
                lowestCapacityHost = (capacity, host)
            }
            if hasCapacity {
                try await Self.sendJob(host: host, job: job, logger: logger)
                return true
            }
        }
        if lowestCapacityHost != nil {
            return false
        } else {
            logger.error("No host found to take job: \(job.id)")
            return false
        }
    }

    func updateStatus(sendJobs: Bool = true) async {
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
                        logger.error("Error getting status for host: \(host.hostname): \(error.localizedDescription)")
                    }
                }
            }

            for (_, job) in await jobs {
                guard job.sentToHost == nil, job.workflowJob.action == .queued else { continue }
                do {
                    if try await handleQueuedJob(job: job) {
                        return
                    }
                } catch {
                    logger.error("Error handling pending job: \(job)")
                }
            }
        }
    }
}
