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

        let sshClient = VirtualMachineSSHClient(
            logger: Self.logger(subsystem: "VirtualMachineSSHClient"),
            client: CitadelSSHClient(
                logger: Self.logger(subsystem: "CitadelSSHClient")
            ),
            ipAddressReader: RetryingVirtualMachineIPAddressReader(),
            credentialsStore: environment,
            connectionHandler: CompositeVirtualMachineSSHConnectionHandler([
                PostBootScriptSSHConnectionHandler(),
                GitHubActionsRunnerSSHConnectionHandler(
                    logger: Self.logger(subsystem: "GitHubActionsRunnerSSHConnectionHandler"),
                    client: NetworkingGitHubClient(
                        credentialsStore: environment,
                        networkingService: URLSessionNetworkingService(
                            logger: Self.logger(subsystem: "URLSessionNetworkingService")
                        )
                    ),
                    credentialsStore: environment,
                    configuration: environment
                )
            ])
        )

        executorServer = ExecutorServer(
            logger: Self.logger(subsystem: "ExecutorServer"),
            virtualMachineProvider: TartVirtualMachineProvider(
                logger: Self.logger(subsystem: "TartVirtualMachineProvider"),
                tart: tart,
                sshClient: sshClient
            ),
            settings: environment
        )
    }

    public func run() async throws {
        // Read contents of home folder to trigger external drive access dialog if needed
        if let homeFolderUrl = environment.homeFolderUrl {
            _ = try? FileManager.default.contentsOfDirectory(at: homeFolderUrl, includingPropertiesForKeys: nil)
        }

        try await executorServer.start()
    }

    private static func logger(subsystem: String) -> Logger {
        ConsoleLogger(subsystem: subsystem)
    }
}
