import EnvironmentSettings
import FileSystemData
import Foundation
import GitHubData
import GitHubDomain
import LoggingData
import LoggingDomain
import NetworkingData
import ShellData
import SSHData
import VirtualMachineData
import VirtualMachineDomain

public protocol ExecutorEnvironment: VirtualMachineSSHCredentialsStore,
                                     TartHomeProvider,
                                     GitHubCredentialsStore,
                                     GitHubActionsRunnerConfiguration,
                                     ExecutorServerSettings { }

public final class ExecutorComposer {
    private let environment: ExecutorEnvironment
    private let executorServer: ExecutorServer

    public init(environment: ExecutorEnvironment) {
        self.environment = environment

        let tart = Tart(
            homeProvider: environment,
            shell: ProcessShell()
        )

        // One client shared by the runner registration handler and the queued-job scanner, so
        // both go through the same GitHub App credentials.
        let gitHubClient = NetworkingGitHubClient(
            credentialsStore: environment,
            networkingService: URLSessionNetworkingService(
                logger: Self.logger(environment, subsystem: "URLSessionNetworkingService")
            )
        )

        let sshClient = VirtualMachineSSHClient(
            logger: Self.logger(environment, subsystem: "VirtualMachineSSHClient"),
            client: CitadelSSHClient(
                logger: Self.logger(environment, subsystem: "CitadelSSHClient")
            ),
            ipAddressReader: RetryingVirtualMachineIPAddressReader(),
            credentialsStore: environment,
            connectionHandler: CompositeVirtualMachineSSHConnectionHandler([
                PostBootScriptSSHConnectionHandler(),
                GitHubActionsRunnerSSHConnectionHandler(
                    logger: Self.logger(environment, subsystem: "GitHubActionsRunnerSSHConnectionHandler"),
                    client: gitHubClient,
                    credentialsStore: environment,
                    configuration: environment
                )
            ])
        )

        let queuedJobsProvider: GitHubQueuedJobsProviding? = environment.gitHubScan.isEnabled
            ? GitHubActionsScanner(
                client: gitHubClient,
                credentialsStore: environment,
                runnerScope: environment.runnerScope,
                configuration: environment.gitHubScan,
                logger: Self.logger(environment, subsystem: "GitHubActionsScanner")
            )
            : nil

        executorServer = ExecutorServer(
            logger: Self.logger(environment, subsystem: "ExecutorServer"),
            virtualMachineProvider: TartVirtualMachineProvider(
                logger: Self.logger(environment, subsystem: "TartVirtualMachineProvider"),
                tart: tart,
                sshClient: sshClient
            ),
            settings: environment,
            queuedJobsProvider: queuedJobsProvider
        )
    }

    public func run() async throws {
        // Read contents of home folder to trigger external drive access dialog if needed
        if let homeFolderUrl = environment.homeFolderUrl {
            _ = try? FileManager.default.contentsOfDirectory(at: homeFolderUrl, includingPropertiesForKeys: nil)
        }

        try await executorServer.start()
    }

    private static func logger(_ environment: ExecutorEnvironment, subsystem: String) -> Logger {
        let consoleLogger = ConsoleLogger(subsystem: subsystem)

        guard let loggingEndpoint = environment.loggingEndpoint else {
            return consoleLogger
        }

        do {
            let endpointLogger = try EndpointLogger(
                subsystem: subsystem,
                hostname: environment.hostname,
                service: "tart-executor",
                endpoint: loggingEndpoint
            )

            return MultiplexLogger(loggers: [consoleLogger, endpointLogger])
        } catch {
            print("Failed to create EndpointLogger: \(error.localizedDescription)")
            return consoleLogger
        }
    }
}
