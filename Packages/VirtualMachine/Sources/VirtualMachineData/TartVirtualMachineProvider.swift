import Foundation
import LoggingDomain
import SSHDomain
import VirtualMachineDomain

public final class TartVirtualMachineProvider<SSHClientType: SSHClient> {
    private let logger: Logger
    private let tart: Tart
    private let sshClient: VirtualMachineSSHClient<SSHClientType>

    public init(logger: Logger, tart: Tart, sshClient: VirtualMachineSSHClient<SSHClientType>) {
        self.logger = logger
        self.tart = tart
        self.sshClient = sshClient
    }
}

extension TartVirtualMachineProvider: VirtualMachineProvider {
    public func createVirtualMachine(
        imageName: String,
        name: String,
        runnerLabels: String?,
        isInsecure: Bool,
        cpu: Int?,
        memory: Int?
    ) async throws -> any VirtualMachine {
        try await tart.pull(sourceName: imageName, isInsecure: isInsecure)
        let virtualMachine = try await TartVirtualMachine(
            tart: tart,
            vmName: imageName,
            runnerLabels: runnerLabels
        ).clone(named: name, isInsecure: isInsecure)
        if let cpu {
            try await virtualMachine.setCpu(cpu)
        }
        if let memory {
            try await virtualMachine.setMemory(memory)
        }
        let connectingVirutalMachine = SSHConnectingVirtualMachine(
            logger: logger,
            virtualMachine: virtualMachine,
            sshClient: sshClient
        )
        return connectingVirutalMachine
    }
}
