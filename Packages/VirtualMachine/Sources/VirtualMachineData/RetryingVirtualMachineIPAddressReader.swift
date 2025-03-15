import VirtualMachineDomain

public final class RetryingVirtualMachineIPAddressReader: VirtualMachineIPAddressReader {
    public init() {}

    public func readIPAddress(
        of virtualMachine: any VirtualMachine,
        shouldUseArpResolver: Bool
    ) async throws -> String {
        do {
            try Task.checkCancellation()
            return try await virtualMachine.getIPAddress(shouldUseArpResolver: shouldUseArpResolver)
        } catch {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            return try await readIPAddress(of: virtualMachine, shouldUseArpResolver: shouldUseArpResolver)
        }
    }
}
