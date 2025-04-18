import Combine
import FlyingFox
import Foundation

public final class WebhookServer {
    private let hostname: String
    private let numberOfMachines: Int
    private let cpuLimit: Int
    private let totalMemory: Int
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let workflowJobSubject = PassthroughSubject<WorkflowJob, Never>()
    private var server: HTTPServer?

    public var inProgressJobs = 0
    public var pendingJobs = 0
    public var startedPendingJobs = 0
    public var virtualMachines = 0
    public var cpuUsed = 0
    public var memoryUsed = 0

    public var workflowJobPublisher: AnyPublisher<WorkflowJob, Never> {
        workflowJobSubject.eraseToAnyPublisher()
    }

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
                workflowJobSubject.send(workflowJob)
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
                workflowJobSubject.send(workflowJob)
            } catch {
                throw error
            }
            return .init(statusCode: .ok)
        }
        await server.appendRoute("GET /metrics") { [weak self] _ in
            guard let self else {
                return .init(statusCode: .badGateway)
            }
            let labels = "{hostname=\"\(hostname)\"}"
            let string = """
tart_executor_in_progress_jobs\(labels) \(inProgressJobs)
tart_executor_pending_jobs\(labels) \(pendingJobs)
tart_executor_started_pending_jobs\(labels) \(startedPendingJobs)
tart_executor_virtual_machines\(labels) \(virtualMachines)
tart_executor_virtual_machine_limit\(labels) \(numberOfMachines)
tart_executor_cpu_limit\(labels) \(cpuLimit)
tart_executor_cpu_used\(labels) \(cpuUsed)
tart_executor_total_memory\(labels) \(totalMemory)
tart_executor_memory_used\(labels) \(memoryUsed)
"""
            let data = Data(string.utf8)
            return .init(statusCode: .ok, body: data)
        }
        await server.appendRoute("GET /status") { [weak self] _ in
            guard let self else {
                return .init(statusCode: .badGateway)
            }

            let status = TartHostStatus(
                inProgressJobs: inProgressJobs,
                pendingJobs: pendingJobs,
                startedPendingJobs: startedPendingJobs,
                activeVirtualMachines: virtualMachines,
                virtualMachineLimit: numberOfMachines,
                cpuLimit: cpuLimit,
                cpuUsed: cpuUsed,
                totalMemory: totalMemory,
                memoryUsed: memoryUsed
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
