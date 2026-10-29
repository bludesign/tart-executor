import EnvironmentSettings
import FlyingFox
import Foundation
import LoggingDomain
import TartCommon

public final class RouterServer {
    private let decoder = JSONDecoder.api
    private var server: HTTPServer?
    let hosts: [TartHost]
    let labels: Set<String>
    let hostname: String
    private let logger: Logger
    let jobHandler: RouterJobHandler
    private var updateTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private let observationSource: RouterGitHubReconciler
    private var reconciliationTask: Task<Void, Never>?
    private let reconciliation: RouterReconciliationConfiguration

    // Management API
    let apiToken: String?
    let startedAt = Date()
    let apiEncoder = JSONEncoder.api
    let apiDecoder = JSONDecoder.api
    private(set) var listeningPort = 0

    public init(
        hosts: [TartHost], labels: Set<String>, hostname: String, apiToken: String?,
        reconciliation: RouterReconciliationConfiguration = .init(), logger: Logger
    ) {
        self.hosts = hosts.sorted { lhs, rhs in
            lhs.priority < rhs.priority
        }
        self.logger = logger
        self.labels = labels
        self.hostname = hostname
        self.apiToken = apiToken
        self.reconciliation = reconciliation
        let source = RouterGitHubReconciler(
            hosts: self.hosts, labels: labels, logger: logger, apiToken: reconciliation.executorApiToken
        )
        observationSource = source
        jobHandler = .init(
            hosts: self.hosts, logger: logger, reconciler: reconciliation.enabled ? source : nil,
            runnerLabels: labels, executorApiToken: reconciliation.executorApiToken
        )
    }

    public func run(port: Int) async throws {
        listeningPort = port
        let server = HTTPServer(port: UInt16(port))
        self.server = server

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
                                LogParameterKey.hostname: host.hostname,
                                LogParameterKey.url: host.url.absoluteString,
                                LogParameterKey.error: error.localizedDescription
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

        await server.appendRoute("POST /") { [weak self] (request: HTTPRequest) in
            guard let self else {
                return .init(statusCode: .badGateway)
            }
            do {
                let bodyData = try await request.bodyData
                let webhookResponse = try decoder.decode(WebhookResponse.self, from: bodyData)
                let workflowJob = WorkflowJob(
                    id: webhookResponse.workflow_job.id,
                    action: webhookResponse.action,
                    labels: webhookResponse.workflow_job.labels,
                    github: webhookResponse.jobContext
                )
                guard labels.isSubset(of: workflowJob.labels) else {
                    logger.error("Workflow job skipped because of labels", parameters: [
                        LogParameterKey.workflowJobId: "\(workflowJob.id)",
                        LogParameterKey.jobLabels: workflowJob.labels.joined(separator: ","),
                        LogParameterKey.tartLabels: labels.joined(separator: ",")
                    ])
                    return .init(statusCode: .ok)
                }
                let job = RouterPendingJob(
                    workflowJob: workflowJob,
                    headers: request.headers.reduce(into: [:]) { headers, element in
                        headers[element.key] = element.value
                    },
                    bodyData: bodyData,
                    pinnedHostname: nil,
                    repository: webhookResponse.repository?.full_name
                )
                let context = webhookResponse.jobContext
                Task { [jobHandler] in await jobHandler.broadcastObservations([context]) }
                await jobHandler.handleJob(job: job)
                return .init(statusCode: .ok)
            } catch {
                throw error
            }
        }

        await registerManagementRoutes(on: server)

        updateTask = Task { [jobHandler] in
            while !Task.isCancelled {
                await jobHandler.updateStatus()
                do { try await Task.sleep(for: .seconds(Constants.updateInterval)) } catch { break }
            }
        }
        if reconciliation.enabled {
            reconciliationTask = Task { [jobHandler, reconciliation] in
                while !Task.isCancelled {
                    await jobHandler.reconcileGitHubJobs()
                    do { try await Task.sleep(for: .seconds(reconciliation.intervalSeconds)) } catch { break }
                }
            }
        }
        if !reconciliation.enabled {
            observationTask = Task { [jobHandler, observationSource] in
                while !Task.isCancelled {
                    await jobHandler.refreshRunnerObservations(using: observationSource)
                    do { try await Task.sleep(for: .seconds(60)) } catch { break }
                }
            }
        }
        defer {
            observationTask?.cancel()
            updateTask?.cancel()
            reconciliationTask?.cancel()
        }

        try await server.run()
    }

    public func stop() async {
        observationTask?.cancel()
        updateTask?.cancel()
        reconciliationTask?.cancel()
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
