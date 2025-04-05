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
import WebServer

extension Environment: @retroactive VirtualMachineFleetSettings {}

let environment = try Environment()

enum Composers {
    static let localNetworkPrivacy = LocalNetworkPrivacy()

    static let tart = Tart(
        homeProvider: environment,
        shell: ProcessShell()
    )

    static let fleetWebhook = VirtualMachineFleetWebhook(
        logger: logger(subsystem: "VirtualMachineFleetWebhook"),
        webhookServer: WebhookServer(
            hostname: environment.hostname,
            numberOfMachines: environment.numberOfMachines,
            cpuLimit: environment.cpuLimit,
            totalMemory: environment.totalMemory
        ),
        virtualMachineProvider: TartVirtualMachineProvider(
            logger: logger(subsystem: "TartVirtualMachineProvider"),
            tart: tart,
            sshClient: sshClient
        ),
        settings: environment
    )

    static let sshClient = VirtualMachineSSHClient(
        logger: logger(subsystem: "VirtualMachineSSHClient"),
        client: CitadelSSHClient(
            logger: logger(subsystem: "CitadelSSHClient")
        ),
        ipAddressReader: RetryingVirtualMachineIPAddressReader(),
        credentialsStore: environment,
        connectionHandler: CompositeVirtualMachineSSHConnectionHandler([
            PostBootScriptSSHConnectionHandler(),
            GitHubActionsRunnerSSHConnectionHandler(
                logger: logger(subsystem: "GitHubActionsRunnerSSHConnectionHandler"),
                client: NetworkingGitHubClient(
                    credentialsStore: environment,
                    networkingService: URLSessionNetworkingService(
                        logger: logger(subsystem: "URLSessionNetworkingService")
                    )
                ),
                credentialsStore: environment,
                configuration: environment
            )
        ])
    )

    static func logger(subsystem: String) -> Logger {
        ConsoleLogger(subsystem: subsystem)
    }
}

Composers.localNetworkPrivacy.checkAccessState { result in
    print("Local network access result: \(result)")
}

Task {
    // Read contents of home folder to trigger external drive access dialog if needed
    if let homeFolderURL = environment.homeFolderURL {
        _ = try? FileManager.default.contentsOfDirectory(at: homeFolderURL, includingPropertiesForKeys: nil)
    }

    try await Composers.fleetWebhook.startCommandLine()
}

RunLoop.main.run()
