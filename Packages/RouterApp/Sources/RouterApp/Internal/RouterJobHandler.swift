import Foundation
import LoggingDomain
import TartCommon

struct CancelJobsRequest: Codable {
    let labels: Set<String>
}

actor RouterJobHandler {
    private enum JobError: Error {
        case errorSending
    }

    private nonisolated let logger: Logger
    private let decoder = JSONDecoder()
    private var jobs = [Int: RouterPendingJob]()
    private var hosts: [TartHost]

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
        func checkJob(job: RouterPendingJob) {
            if job.sentToHost == nil {
                let workflowJob = job.workflowJob
                guard let existingJob = jobs.values.first(where: { existingJob in
                    existingJob.id != workflowJob.id &&
                    existingJob.workflowJob.labels == workflowJob.labels &&
                    existingJob.workflowJob.action == .queued &&
                    existingJob.sentToHost != nil
                }) else {
                    logger.error("Error no existing job found", parameters: [
                        "jobId": "\(job.id)",
                        "workflowJobId": "\(job.workflowJob.id)",
                        "labels": job.workflowJob.labels.joined(separator: ",")
                    ])
                    return
                }
                job.sentToHost = existingJob.sentToHost
                existingJob.sentToHost = nil
            }
        }

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
            job.workflowJob = newJob.workflowJob
        case .completed:
            guard let removedJob = jobs.removeValue(forKey: newJob.id) else { return }
            checkJob(job: removedJob)

            let otherInProgress = jobs.values.filter { existingJob in
                existingJob.workflowJob.labels == removedJob.workflowJob.labels
            }.count
            if otherInProgress == 0 {
                // Send API call to other hosts to cancel jobs with these labels.
                await cancelJobsWithLabels(removedJob.workflowJob.labels)
            }
            return
        case .waiting, .unknown, .routerStart:
            return
        }
        let workflowJob = job.workflowJob

        switch workflowJob.action {
        case .inProgress:
            checkJob(job: job)
        case .queued, .completed, .waiting, .unknown, .routerStart:
            break
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
                        logger.error("Error sending cancel request to host", parameters: [
                            "hostname": host.hostname,
                            "labels": labels.joined(separator: ","),
                            "error": error.localizedDescription
                        ])
                    }
                }
            }
        }
    }

    func updateStatus(shouldSendJobs: Bool = true) async {
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
                        logger.error("Error getting status for host", parameters: [
                            "hostname": host.hostname,
                            "url": host.url.absoluteString,
                            "error": error.localizedDescription
                        ])
                    }
                }
            }

            guard shouldSendJobs else { return }
            // Try to send all queued jobs that haven't been sent yet
            // Continue even if one fails, to maximize throughput across multiple hosts
            for (_, job) in await jobs {
                guard job.sentToHost == nil, job.workflowJob.action == .queued else { continue }
                do {
                    _ = try await handleQueuedJob(job: job)
                } catch {
                    logger.error("Error handling pending job", parameters: [
                        "jobId": "\(job.id)",
                        "workflowJobId": "\(job.workflowJob.id)",
                        "error": error.localizedDescription
                    ])
                }
            }
        }
    }
}

private extension RouterJobHandler {
    static func sendJob(host: TartHost, job: RouterPendingJob, logger: Logger) async throws {
        logger.info("Sending job to host", parameters: [
            "jobId": "\(job.id)",
            "workflowJobId": "\(job.workflowJob.id)",
            "hostname": host.hostname,
            "labels": job.workflowJob.labels.joined(separator: ",")
        ])
        var hostRequest = URLRequest(url: host.url.appending(path: "/router"))
        hostRequest.httpMethod = "POST"
        hostRequest.httpBody = job.bodyData
        job.headers.forEach { header, value in
            hostRequest.setValue(value, forHTTPHeaderField: header.rawValue)
        }
        let (_, response) = try await URLSession.shared.data(for: hostRequest)
        if (response as? HTTPURLResponse)?.statusCode == 200 {
            job.sentToHost = host
            host.lastStatus?.activeVirtualMachines += 1
        } else {
            throw JobError.errorSending
        }
    }

    static func cancelJobsByLabels(host: TartHost, labels: Set<String>, logger: Logger) async throws {
        logger.info("Sending cancel request to host", parameters: [
            "hostname": host.hostname,
            "labels": labels.joined(separator: ",")
        ])
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

    @discardableResult
    func handleQueuedJob(job: RouterPendingJob) async throws -> Bool {
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
                do {
                    try await Self.sendJob(host: host, job: job, logger: logger)
                    return true
                } catch {
                    logger.error("Failed to send job to host", parameters: [
                        "jobId": "\(job.id)",
                        "workflowJobId": "\(job.workflowJob.id)",
                        "hostname": host.hostname,
                        "error": error.localizedDescription
                    ])
                }
            }
        }
        if lowestCapacityHost != nil {
            return false
        } else {
            logger.error("No host found to take job", parameters: [
                "jobId": "\(job.id)",
                "workflowJobId": "\(job.workflowJob.id)",
                "labels": job.workflowJob.labels.joined(separator: ",")
            ])
            return false
        }
    }
}
