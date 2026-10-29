import Foundation
import LoggingDomain
import SSHDomain
@testable import VirtualMachineData
import VirtualMachineDomain
import XCTest

final class TartVirtualMachineProviderTests: XCTestCase {
    func testConfigurationFailureDeletesCloneBeforeRethrowing() async {
        for failure in [ConfigurationFailure.cpu, .memory] {
            let virtualMachine = ConfiguringVirtualMachine(failure: failure)
            let logger = ConfigurationLogger()

            do {
                try await TartVirtualMachineProvider<UnusedSSHClient>.configureVirtualMachine(
                    virtualMachine, cpu: 7, memory: 24_576, logger: logger
                )
                XCTFail("Expected configuration failure")
            } catch {
                XCTAssertEqual(error as? ConfigurationFailure, failure)
            }

            XCTAssertEqual(virtualMachine.operations, failure == .cpu ? ["cpu", "delete"] : ["cpu", "memory", "delete"])
            XCTAssertTrue(logger.errors.isEmpty)
        }
    }

    func testCleanupFailurePreservesConfigurationErrorAndLogsCloneName() async {
        let virtualMachine = ConfiguringVirtualMachine(failure: .memory, deletionFails: true)
        let logger = ConfigurationLogger()

        do {
            try await TartVirtualMachineProvider<UnusedSSHClient>.configureVirtualMachine(
                virtualMachine, cpu: 7, memory: 24_576, logger: logger
            )
            XCTFail("Expected configuration failure")
        } catch {
            XCTAssertEqual(error as? ConfigurationFailure, .memory)
        }

        XCTAssertEqual(virtualMachine.operations, ["cpu", "memory", "delete"])
        XCTAssertEqual(logger.errors.count, 1)
        XCTAssertTrue(logger.errors[0].contains(virtualMachine.name))
        XCTAssertTrue(logger.errors[0].contains("cleanup failed"))
    }

    func testSuccessfulConfigurationKeepsClone() async throws {
        let virtualMachine = ConfiguringVirtualMachine()

        try await TartVirtualMachineProvider<UnusedSSHClient>.configureVirtualMachine(
            virtualMachine, cpu: 7, memory: 24_576, logger: ConfigurationLogger()
        )

        XCTAssertEqual(virtualMachine.operations, ["cpu", "memory"])
    }
}

private enum ConfigurationFailure: LocalizedError {
    case cpu, memory, cleanup

    var errorDescription: String? {
        switch self {
        case .cpu:
            "CPU configuration failed"
        case .memory:
            "Memory configuration failed"
        case .cleanup:
            "cleanup failed"
        }
    }
}

private final class ConfigurationLogger: Logger {
    private(set) var errors = [String]()

    func info(_: String, parameters _: [String: String]?) {}
    func error(_ message: String, parameters _: [String: String]?) {
        errors.append(message)
    }
}

private final class ConfiguringVirtualMachine: VirtualMachine {
    let name = "tart-executor-test-clone"
    let canStart = true
    let runnerLabels: String? = nil
    private(set) var operations = [String]()
    private let failure: ConfigurationFailure?
    private let deletionFails: Bool

    init(failure: ConfigurationFailure? = nil, deletionFails: Bool = false) {
        self.failure = failure
        self.deletionFails = deletionFails
    }

    func start(netBridgedAdapter _: String?, isHeadless _: Bool) async throws {}
    func setCpu(_: Int) async throws {
        operations.append("cpu")
        if failure == .cpu { throw ConfigurationFailure.cpu }
    }
    func setMemory(_: Int) async throws {
        operations.append("memory")
        if failure == .memory { throw ConfigurationFailure.memory }
    }
    func clone(named _: String, isInsecure _: Bool) async throws -> VirtualMachine { self }
    func delete() async throws {
        operations.append("delete")
        if deletionFails { throw ConfigurationFailure.cleanup }
    }
    func getIPAddress(shouldUseArpResolver _: Bool) async throws -> String { "127.0.0.1" }
}

private struct UnusedSSHClient: SSHClient {
    func connect(host _: String, username _: String, password _: String) async throws -> UnusedSSHConnection {
        throw ConfigurationFailure.cleanup
    }
}

private struct UnusedSSHConnection: SSHConnection {
    func executeCommand(_: String) async throws {}
    func close() async throws {}
}
