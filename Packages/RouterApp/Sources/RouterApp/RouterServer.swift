import Combine
import FlyingFox
import Foundation
import LoggingDomain
import TartCommon

public final class RouterServer {
    private let decoder = JSONDecoder()
    private var server: HTTPServer?
    private let hosts: [TartHost]
    private let labels: Set<String>
    private let hostname: String
    private let logger: Logger
    private let jobHandler: RouterJobHandler
    private var timer: Timer?

    public init(hosts: [TartHost], labels: Set<String>, hostname: String, logger: Logger) {
        self.hosts = hosts.sorted { lhs, rhs in
            lhs.priority < rhs.priority
        }
        self.logger = logger
        self.labels = labels
        self.hostname = hostname
        jobHandler = .init(hosts: hosts, logger: logger)

        Task {
            await jobHandler.updateStatus(shouldSendJobs: false)
        }

        timer = .scheduledTimer(withTimeInterval: Constants.updateInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.jobHandler.updateStatus()
            }
        }
    }

    public func run(port: Int) async throws {
        let server = HTTPServer(port: UInt16(port))

        await server.appendRoute("GET /metrics") { [weak self] _ in
            guard let self else {
                return .init(statusCode: .badGateway)
            }
            let strings = try await withThrowingTaskGroup(of: String.self) { [hostname, hosts, jobHandler, logger] group in
                hosts.forEach { host in
                    group.addTask {
                        do {
                            let url = host.url.appending(path: "/metrics")
                            let (data, _) = try await URLSession.shared.data(from: url)
                            guard let string = String(data: data, encoding: .utf8) else {
                                throw RouterError.wrongBody
                            }
                            return string.appending("\ntart_executor_reachable{hostname=\"\(host.hostname)\"} 1")
                        } catch {
                            logger.error("Error getting status for host", parameters: [
                                "hostname": host.hostname,
                                "url": host.url.absoluteString,
                                "error": error.localizedDescription
                            ])
                            return "tart_executor_reachable{hostname=\"\(host.hostname)\"} 0"
                        }
                    }
                }

                var results: [String] = []
                for try await result in group {
                    results.append(result)
                }

                let pendingJobs = await jobHandler.pendingJobs
                let pendingJobsUnsent = await jobHandler.pendingJobsUnsent
                let pendingJobsQueued = await jobHandler.pendingJobsQueued
                let availableVirtualMachines = await jobHandler.availableVirtualMachines
                let availableHosts = await jobHandler.availableHosts

                results.append("tart_router_pending_jobs{hostname=\"\(hostname)\"} \(pendingJobs)")
                results.append("tart_router_pending_jobs_unsent{hostname=\"\(hostname)\"} \(pendingJobsUnsent)")
                results.append("tart_router_pending_jobs_queued{hostname=\"\(hostname)\"} \(pendingJobsQueued)")
                results.append("tart_router_available_virtual_machines{hostname=\"\(hostname)\"} \(availableVirtualMachines)")
                results.append("tart_router_available_hosts{hostname=\"\(hostname)\"} \(availableHosts)")

                return results
            }
            let status = strings.joined(separator: "\n")
            return .init(statusCode: .ok, headers: [.init(rawValue: "Content-Type"): "text/plain; version=0.0.4"], body: Data(status.utf8))
        }

        await server.appendRoute("POST /runner") { [weak self] _ in
            guard let self else {
                return .init(statusCode: .badGateway)
            }
            await jobHandler.updateStatus()
            return .init(statusCode: .ok)
        }

        await server.appendRoute("POST /") { [weak self] request in
            guard let self else {
                return .init(statusCode: .badGateway)
            }
            do {
                let bodyData = try await request.bodyData
                let webhookResponse = try decoder.decode(WebhookResponse.self, from: bodyData)
                let workflowJob = WorkflowJob(
                    id: webhookResponse.workflow_job.id,
                    action: webhookResponse.action,
                    labels: webhookResponse.workflow_job.labels
                )
                guard labels.isSubset(of: workflowJob.labels) else {
                    logger.error("Workflow job skipped because of labels", parameters: [
                        "workflowJobId": "\(workflowJob.id)",
                        "jobLabels": workflowJob.labels.joined(separator: ","),
                        "tartLabels": labels.joined(separator: ",")
                    ])
                    return .init(statusCode: .ok)
                }
                await jobHandler.handleJob(job: .init(workflowJob: workflowJob, headers: request.headers, bodyData: bodyData))
                return .init(statusCode: .ok)
            } catch {
                throw error
            }
        }

        try await server.run()
    }

    public func stop() async {
        await server?.stop()
        server = nil
    }
}

// MARK: - Private

private extension RouterServer {
    enum Constants {
        static let updateInterval: TimeInterval = 5
    }

    enum RouterError: Error {
        case wrongBody
    }
}
