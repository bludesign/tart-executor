import Combine
import FlyingFox
import Foundation

public protocol FleetHandler: AnyObject {
    func getJobStatus() async -> JobStatus
    func handleWorkflowJob(_ workflowJob: WorkflowJob) async
}

public struct JobStatus {
    public let inProgressJobs: Int
    public let pendingJobs: Int
    public let startedPendingJobs: Int
    public let virtualMachines: Int
    public let cpuUsed: Int
    public let memoryUsed: Int

    public init(inProgressJobs: Int, pendingJobs: Int, startedPendingJobs: Int, virtualMachines: Int, cpuUsed: Int, memoryUsed: Int) {
        self.inProgressJobs = inProgressJobs
        self.pendingJobs = pendingJobs
        self.startedPendingJobs = startedPendingJobs
        self.virtualMachines = virtualMachines
        self.cpuUsed = cpuUsed
        self.memoryUsed = memoryUsed
    }
}

public final class WebhookServer {
    private let hostname: String
    private let numberOfMachines: Int
    private let cpuLimit: Int
    private let totalMemory: Int
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var server: HTTPServer?
    public weak var fleetHandler: FleetHandler?

    public init(hostname: String, numberOfMachines: Int, cpuLimit: Int, totalMemory: Int) {
        self.hostname = hostname
        self.numberOfMachines = numberOfMachines
        self.cpuLimit = cpuLimit
        self.totalMemory = totalMemory
    }

    public func run(port: Int) async throws {
        let server = HTTPServer(port: UInt16(port))
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
                await fleetHandler?.handleWorkflowJob(workflowJob)
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
                await fleetHandler?.handleWorkflowJob(workflowJob)
            } catch {
                throw error
            }
            return .init(statusCode: .ok)
        }
        await server.appendRoute("GET /metrics") { [weak self] _ in
            guard let self, let jobStatus = await fleetHandler?.getJobStatus() else {
                return .init(statusCode: .badGateway)
            }
            let labels = "{hostname=\"\(hostname)\"}"
            let string = """
tart_executor_in_progress_jobs\(labels) \(jobStatus.inProgressJobs)
tart_executor_pending_jobs\(labels) \(jobStatus.pendingJobs)
tart_executor_started_pending_jobs\(labels) \(jobStatus.startedPendingJobs)
tart_executor_virtual_machines\(labels) \(jobStatus.virtualMachines)
tart_executor_virtual_machine_limit\(labels) \(numberOfMachines)
tart_executor_cpu_limit\(labels) \(cpuLimit)
tart_executor_cpu_used\(labels) \(jobStatus.cpuUsed)
tart_executor_total_memory\(labels) \(totalMemory)
tart_executor_memory_used\(labels) \(jobStatus.memoryUsed)
"""
            let data = Data(string.utf8)
            return .init(statusCode: .ok, body: data)
        }
        await server.appendRoute("GET /status") { [weak self] _ in
            guard let self, let jobStatus = await fleetHandler?.getJobStatus() else {
                return .init(statusCode: .badGateway)
            }

            let status = TartHostStatus(
                inProgressJobs: jobStatus.inProgressJobs,
                pendingJobs: jobStatus.pendingJobs,
                startedPendingJobs: jobStatus.startedPendingJobs,
                activeVirtualMachines: jobStatus.virtualMachines,
                virtualMachineLimit: numberOfMachines,
                cpuLimit: cpuLimit,
                cpuUsed: jobStatus.cpuUsed,
                totalMemory: totalMemory,
                memoryUsed: jobStatus.memoryUsed
            )

            let body = try encoder.encode(status)
            return .init(statusCode: .ok, body: body)
        }
        try await server.run()
    }

    public func stop() async {
        await server?.stop()
        server = nil
    }
}
