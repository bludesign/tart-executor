import Combine
import Foundation
import LoggingDomain
import WebServer

public protocol VirtualMachineFleetSettings {
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
}

public final class VirtualMachineFleetWebhook {
    private let logger: Logger
    private let webhookServer: WebhookServer
    private var webhookServerTask: Task<(), any Error>?
    private let jobHandler: JobHandler
    private var gitHubRunnerLabels: Set<String>
    private var cancellables = Set<AnyCancellable>()
    private let settings: VirtualMachineFleetSettings

    public init(logger: Logger, webhookServer: WebhookServer, virtualMachineProvider: VirtualMachineProvider, settings: VirtualMachineFleetSettings) {
        self.logger = logger
        self.webhookServer = webhookServer
        self.settings = settings
        let labelsArray = settings.runnerLabels.components(separatedBy: ",").map { label in
            label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        gitHubRunnerLabels = Set<String>(labelsArray)
        jobHandler = .init(
            routerUrl: settings.routerUrl,
            virtualMachineProvider: virtualMachineProvider,
            logger: logger
        )

        webhookServer.fleetHandler = self

        Task {
            await jobHandler.set(numberOfMachines: settings.numberOfMachines)

            if let localUrl = settings.localUrl.flatMap({ URL(string: $0) }) {
                do {
                    _ = try await URLSession.shared.data(from: localUrl)
                } catch {
                    logger.error("Error calling local url: \(error)")
                }
            }
        }
    }

    public func startCommandLine() async throws {
        logger.info("Starting web server on port: \(settings.webhookPort) numberOfMachines: \(settings.numberOfMachines)")
        try await webhookServer.run(port: settings.webhookPort)
    }
}

extension VirtualMachineFleetWebhook: FleetHandler {
    public func getJobStatus() async -> JobStatus {
        await jobHandler.jobStatus
    }

    public func handleWorkflowJob(_ workflowJob: WorkflowJob) async -> Bool {
        guard gitHubRunnerLabels.isSubset(of: workflowJob.labels) else {
            logger.error("Workflow job skipped because of labels. Job labels: \(workflowJob.labels) Tart labels: \(gitHubRunnerLabels)")
            return false
        }

        let cpu = workflowJob.cpu ?? settings.defaultCpu
        let memory = workflowJob.memory ?? settings.defaultMemory
        let workflowSet = workflowJob.filteredLabels.subtracting(gitHubRunnerLabels)

        guard workflowSet.count == 1, let imageName = workflowSet.first else {
            logger.error("Workflow job skipped extra labels found: \(workflowSet)")
            return false
        }

        let imageInsecure = settings.insecureDomains.contains { insecureDomain in
            imageName.contains(insecureDomain)
        }

        let isJobInsecure = settings.isInsecure || imageInsecure

        logger.info("Workflow job: \(workflowJob.id) action: \(workflowJob.action.rawValue) image: \(imageName) isInsecure: \(isJobInsecure)")

        let pendingJob = PendingJob(
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
