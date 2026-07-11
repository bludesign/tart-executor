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
    /// Lists the names of all local Tart virtual machines / images.
    func listVirtualMachines() async throws -> [String]
    /// Deletes a single virtual machine by name.
    func deleteVirtualMachine(name: String) async throws
    /// Pulls an image into the local Tart store.
    func pullImage(name: String, isInsecure: Bool) async throws
    /// Returns the IP address of a running virtual machine.
    func ipAddress(ofVirtualMachineNamed name: String) async throws -> String
}
