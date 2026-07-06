import Foundation

public protocol VirtualMachineProvider: AnyObject {
    func createVirtualMachine(
        imageName: String,
        name: String,
        runnerLabels: String?,
        isInsecure: Bool,
        cpu: Int?,
        memory: Int?
    ) async throws -> VirtualMachine
    /// Removes all virtual machines whose name starts with the given prefix and returns the
    /// names of the machines that were removed.
    func removeVirtualMachines(namePrefix: String) async throws -> [String]
}
