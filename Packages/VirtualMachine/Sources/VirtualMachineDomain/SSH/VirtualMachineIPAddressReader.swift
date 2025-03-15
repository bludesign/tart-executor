public protocol VirtualMachineIPAddressReader {
    func readIPAddress(of virtualMachine: VirtualMachine, shouldUseArpResolver: Bool) async throws -> String
}
