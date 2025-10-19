import Combine
import FlyingFox
import Foundation
import LoggingDomain
import TartCommon
import VirtualMachineDomain

struct CancelJobsRequest: Codable {
    let labels: Set<String>
}

public protocol ExecutorServerSettings {
    var numberOfMachines: Int { get }
    var runnerLabels: String { get }
    var webhookPort: Int { get }
    var routerUrl: String? { get }
    var localUrl: String? { get }
    var isHeadless: Bool { get }
    var isInsecure: Bool { get }
    var insecureDomains: [String] { get }
    var netBridgedAdapter: String? { get }
    var defaultCpu: Int? { get }
    var defaultMemory: Int? { get }
    var hostname: String { get }
    var cpuLimit: Int { get }
    var totalMemory: Int { get }
    var loggingEndpoint: String? { get }
}

final class ExecutorServer {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var server: HTTPServer?

    // Fleet webhook functionality
    private let logger: Logger
    private var executorServerTask: Task<(), any Error>?
    private let jobHandler: ExecutorJobHandler
    private var gitHubRunnerLabels: Set<String>
    private var cancellables = Set<AnyCancellable>()
    private let settings: ExecutorServerSettings

    init(logger: Logger, virtualMachineProvider: VirtualMachineProvider, settings: ExecutorServerSettings) {
        self.logger = logger
        self.settings = settings

        let labelsArray = settings.runnerLabels.components(separatedBy: ",").map { label in
            label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        gitHubRunnerLabels = Set<String>(labelsArray)
        jobHandler = .init(
            routerUrl: settings.routerUrl,
            virtualMachineProvider: virtualMachineProvider,
            logger: logger,
            numberOfMachines: settings.numberOfMachines
        )

        Task {
            if let localUrl = settings.localUrl.flatMap({ URL(string: $0) }) {
                do {
                    _ = try await URLSession.shared.data(from: localUrl)
                } catch {
                    logger.error("Error calling local url", parameters: [
                        LogParameterKey.url: localUrl.absoluteString,
                        LogParameterKey.error: error.localizedDescription
                    ])
                }
            }
        }
    }

    func start() async throws {
        logger.info("Starting web server", parameters: [
            LogParameterKey.port: "\(settings.webhookPort)",
            LogParameterKey.numberOfMachines: "\(settings.numberOfMachines)",
            LogParameterKey.hostname: settings.hostname
        ])
        let server = HTTPServer(port: UInt16(settings.webhookPort))
        self.server = server

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
                let result = await handleWorkflowJob(workflowJob)
                if !result {
                    return .init(statusCode: .badGateway)
                }
            } catch {
                throw error
            }
            return .init(statusCode: .ok)
        }

        await server.appendRoute("POST /router") { [weak self] request in
            guard let self else {
                return .init(statusCode: .badGateway)
            }
            do {
                let bodyData = try await request.bodyData
                let webhookResponse = try decoder.decode(WebhookResponse.self, from: bodyData)
                let workflowJob = WorkflowJob(
                    id: webhookResponse.workflow_job.id,
                    action: .routerStart,
                    labels: webhookResponse.workflow_job.labels
                )
                let result = await handleWorkflowJob(workflowJob)
                if !result {
                    return .init(statusCode: .badGateway)
                }
            } catch {
                throw error
            }
            return .init(statusCode: .ok)
        }

        await server.appendRoute("GET /metrics") { [weak self] _ in
            guard let self else {
                return .init(statusCode: .badGateway)
            }
            let jobStatus = await jobHandler.jobStatus
            let labels = "{hostname=\"\(settings.hostname)\"}"
            let string = """
tart_executor_in_progress_jobs\(labels) \(jobStatus.inProgressJobs)
tart_executor_pending_jobs\(labels) \(jobStatus.pendingJobs)
tart_executor_started_pending_jobs\(labels) \(jobStatus.startedPendingJobs)
tart_executor_virtual_machines\(labels) \(jobStatus.virtualMachines)
tart_executor_virtual_machine_limit\(labels) \(settings.numberOfMachines)
tart_executor_cpu_limit\(labels) \(settings.cpuLimit)
tart_executor_cpu_used\(labels) \(jobStatus.cpuUsed)
tart_executor_total_memory\(labels) \(settings.totalMemory)
tart_executor_memory_used\(labels) \(jobStatus.memoryUsed)
"""
            let data = Data(string.utf8)
            return .init(statusCode: .ok, body: data)
        }

        await server.appendRoute("GET /status") { [weak self] _ in
            guard let self else {
                return .init(statusCode: .badGateway)
            }
            let jobStatus = await jobHandler.jobStatus

            let status = TartHostStatus(
                inProgressJobs: jobStatus.inProgressJobs,
                pendingJobs: jobStatus.pendingJobs,
                startedPendingJobs: jobStatus.startedPendingJobs,
                activeVirtualMachines: jobStatus.virtualMachines,
                virtualMachineLimit: settings.numberOfMachines,
                cpuLimit: settings.cpuLimit,
                cpuUsed: jobStatus.cpuUsed,
                totalMemory: settings.totalMemory,
                memoryUsed: jobStatus.memoryUsed
            )

            let body = try encoder.encode(status)
            return .init(statusCode: .ok, body: body)
        }

        await server.appendRoute("POST /cancel") { [weak self] request in
            guard let self else {
                return .init(statusCode: .badGateway)
            }
            do {
                let bodyData = try await request.bodyData
                let cancelRequest = try decoder.decode(CancelJobsRequest.self, from: bodyData)
                await jobHandler.cancelJobsByLabels(cancelRequest.labels)
                return .init(statusCode: .ok)
            } catch {
                logger.error("Error processing cancel request", parameters: [
                    LogParameterKey.error: error.localizedDescription
                ])
                return .init(statusCode: .badRequest)
            }
        }
        try await server.run()
    }

    func stop() async {
        await server?.stop()
        server = nil
    }
}

private extension ExecutorServer {
    func handleWorkflowJob(_ workflowJob: WorkflowJob) async -> Bool {
        guard gitHubRunnerLabels.isSubset(of: workflowJob.labels) else {
            logger.error("Workflow job skipped because of labels", parameters: [
                LogParameterKey.workflowJobId: "\(workflowJob.id)",
                LogParameterKey.jobLabels: workflowJob.labels.joined(separator: ","),
                LogParameterKey.tartLabels: gitHubRunnerLabels.joined(separator: ",")
            ])
            return false
        }

        let cpu = workflowJob.cpu ?? settings.defaultCpu
        let memory = workflowJob.memory ?? settings.defaultMemory
        let workflowSet = workflowJob.filteredLabels.subtracting(gitHubRunnerLabels)

        guard workflowSet.count == 1, let imageName = workflowSet.first else {
            logger.error("Workflow job skipped extra labels found", parameters: [
                LogParameterKey.workflowJobId: "\(workflowJob.id)",
                LogParameterKey.extraLabels: workflowSet.joined(separator: ","),
                LogParameterKey.expectedCount: "1",
                LogParameterKey.actualCount: "\(workflowSet.count)"
            ])
            return false
        }

        let imageInsecure = settings.insecureDomains.contains { insecureDomain in
            imageName.contains(insecureDomain)
        }

        let isJobInsecure = settings.isInsecure || imageInsecure

        logger.info("Workflow job received", parameters: [
            LogParameterKey.workflowJobId: "\(workflowJob.id)",
            LogParameterKey.action: workflowJob.action.rawValue,
            LogParameterKey.imageName: imageName,
            LogParameterKey.isInsecure: "\(isJobInsecure)",
            LogParameterKey.cpu: cpu.map { "\($0)" } ?? "default",
            LogParameterKey.memory: memory.map { "\($0)" } ?? "default"
        ])

        let pendingJob = ExecutorPendingJob(
            workflowJob: workflowJob,
            imageName: imageName,
            netBridgedAdapter: settings.netBridgedAdapter,
            isInsecure: isJobInsecure,
            isHeadless: settings.isHeadless,
            cpu: cpu,
            memory: memory
        )
        return await jobHandler.handle(pendingJob: pendingJob)
    }
}
