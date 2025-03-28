import Foundation
import LoggingDomain
import SSHDomain

private enum VirtualMachineSSHClientError: LocalizedError, CustomDebugStringConvertible {
    case missingSSHUsername
    case missingSSHPassword
    case failedConnectingToVirtualMachineAfterRetries

    var errorDescription: String? {
        debugDescription
    }

    var debugDescription: String {
        switch self {
        case .missingSSHUsername:
            "The SSH username is not set in Tartelet's settings."
        case .missingSSHPassword:
            "The SSH password is not set in Tartelet's settings."
        case .failedConnectingToVirtualMachineAfterRetries:
            "Failed establishing connection to virtual machine after retrying a number of times."
        }
    }
}

public final class VirtualMachineSSHClient<SSHClientType: SSHClient> {
    private let logger: Logger
    private let client: SSHClientType
    private let ipAddressReader: VirtualMachineIPAddressReader
    private let credentialsStore: VirtualMachineSSHCredentialsStore
    private let connectionHandler: VirtualMachineSSHConnectionHandler

    public init(
        logger: Logger,
        client: SSHClientType,
        ipAddressReader: VirtualMachineIPAddressReader,
        credentialsStore: VirtualMachineSSHCredentialsStore,
        connectionHandler: VirtualMachineSSHConnectionHandler
    ) {
        self.logger = logger
        self.client = client
        self.ipAddressReader = ipAddressReader
        self.credentialsStore = credentialsStore
        self.connectionHandler = connectionHandler
    }

    func connect(
        to virtualMachine: VirtualMachine,
        shouldUseArpResolver: Bool
    ) async throws -> SSHClientType.SSHConnectionType {
        let ipAddress = try await getIPAddress(of: virtualMachine, shouldUseArpResolver: shouldUseArpResolver)
        logger.info("Got IP address of virtual machine named \(virtualMachine.name): \(ipAddress)")
        let connection = try await connectToVirtualMachine(
            named: virtualMachine.name,
            on: ipAddress,
            maximumAttempts: 3
        )
        logger.info("Did connect to virtual machine named \(virtualMachine.name): \(ipAddress)")
        try await connectionHandler.didConnect(to: virtualMachine, through: connection)
        return connection
    }
}

private extension VirtualMachineSSHClient {
    private func getIPAddress(of virtualMachine: VirtualMachine, shouldUseArpResolver: Bool) async throws -> String {
        do {
            return try await ipAddressReader.readIPAddress(
                of: virtualMachine,
                shouldUseArpResolver: shouldUseArpResolver
            )
        } catch {
            logger.error(
                "Failed obtaining IP address of virtual machine named \(virtualMachine.name): "
                + error.localizedDescription
            )
            throw error
        }
    }

    private func connectToVirtualMachine(
        named virtualMachineName: String,
        on host: String,
        attempt: Int = 1,
        maximumAttempts: Int
    ) async throws -> SSHClientType.SSHConnectionType {
        do {
            try Task.checkCancellation()
            return try await connectToVirtualMachine(named: virtualMachineName, on: host)
        } catch {
            logger.error(
                "Attempt \(attempt) out of \(maximumAttempts) to establish an SSH connection"
                + " to the virtual machine named \(virtualMachineName) failed."
            )
            guard attempt < maximumAttempts else {
                logger.error(
                    "Last attempt to establish an SSH connection to"
                    + " virtual machine named \(virtualMachineName) failed."
                )
                throw VirtualMachineSSHClientError.failedConnectingToVirtualMachineAfterRetries
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            return try await connectToVirtualMachine(
                named: virtualMachineName,
                on: host,
                attempt: attempt + 1,
                maximumAttempts: maximumAttempts
            )
        }
    }

    private func connectToVirtualMachine(
        named virtualMachineName: String,
        on host: String
    ) async throws -> SSHClientType.SSHConnectionType {
        guard let username = credentialsStore.username else {
            logger.error(
                "Failed connecting to to \(virtualMachineName) on \(host)."
                + " The SSH username is not set in Tartelet's settings."
            )
            throw VirtualMachineSSHClientError.missingSSHUsername
        }
        guard let password = credentialsStore.password else {
            logger.error(
                "Failed connecting to to \(virtualMachineName) on \(host)."
                + " The SSH password is not set in Tartelet's settings."
            )
            throw VirtualMachineSSHClientError.missingSSHPassword
        }
        do {
            return try await client.connect(host: host, username: username, password: password)
        } catch {
            logger.error(
                "Failed connecting to \(virtualMachineName) on \(host): "
                + error.localizedDescription
            )
            throw error
        }
    }
}
