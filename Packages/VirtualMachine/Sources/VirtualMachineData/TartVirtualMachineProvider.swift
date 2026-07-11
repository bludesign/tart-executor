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

    public func removeVirtualMachines(namePrefix: String) async throws -> [String] {
        let virtualMachineNames = try await tart.list()
        var removedNames = [String]()
        for virtualMachineName in virtualMachineNames where virtualMachineName.hasPrefix(namePrefix) {
            do {
                try await tart.delete(name: virtualMachineName)
                removedNames.append(virtualMachineName)
            } catch {
                logger.error("Failed removing virtual machine \(virtualMachineName): \(error.localizedDescription)")
            }
        }
        return removedNames
    }

    public func listVirtualMachines() async throws -> [String] {
        try await tart.list()
    }

    public func deleteVirtualMachine(name: String) async throws {
        try await tart.delete(name: name)
    }

    public func pullImage(name: String, isInsecure: Bool) async throws {
        try await tart.pull(sourceName: name, isInsecure: isInsecure)
    }

    public func ipAddress(ofVirtualMachineNamed name: String) async throws -> String {
        try await tart.getIPAddress(ofVirtualMachineNamed: name, shouldUseArpResolver: false)
    }
}
