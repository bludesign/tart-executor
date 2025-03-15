import Foundation

public protocol VirtualMachine {
    var name: String { get }
    var canStart: Bool { get }
    var runnerLabels: String? { get }
    func start(netBridgedAdapter: String?, isHeadless: Bool) async throws
    func setCpu(_ cpu: Int) async throws
    func setMemory(_ memory: Int) async throws
    func clone(named newName: String, isInsecure: Bool) async throws -> VirtualMachine
    func delete() async throws
    func getIPAddress(shouldUseArpResolver: Bool) async throws -> String
}
