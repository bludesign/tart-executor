@testable import ExecutorApp
import Foundation
import LoggingDomain
import TartCommon
import VirtualMachineDomain
import XCTest

final class ResourceSchedulingTests: XCTestCase {
    func testRouterStartRejectsSecondLargeJobButAcceptsSmallJob() async {
        let handler = makeHandler()
        let large = makeJob(id: 1, action: .routerStart, cpu: 7, memory: 24_576)
        let secondLarge = makeJob(id: 2, action: .routerStart, cpu: 7, memory: 24_576)
        let small = makeJob(id: 3, action: .routerStart, cpu: 2, memory: 4_096)

        let startedLarge = await handler.handle(pendingJob: large)
        let startedSecondLarge = await handler.handle(pendingJob: secondLarge)
        let startedSmall = await handler.handle(pendingJob: small)

        XCTAssertTrue(startedLarge)
        XCTAssertFalse(startedSecondLarge)
        XCTAssertTrue(startedSmall)

        let status = await handler.jobStatus
        XCTAssertEqual(status.virtualMachines, 2)
        XCTAssertEqual(status.cpuUsed, 9)
        XCTAssertEqual(status.memoryUsed, 28_672)
        await handler.cancelAll()
    }

    func testDirectQueueBackfillsSmallerJob() async {
        let handler = makeHandler()
        let running = makeJob(id: 1, action: .routerStart, cpu: 7, memory: 24_576)
        let blocked = makeJob(id: 2, action: .queued, cpu: 7, memory: 24_576)
        let small = makeJob(id: 3, action: .queued, cpu: 2, memory: 4_096)

        let startedRunning = await handler.handle(pendingJob: running)
        let queuedBlocked = await handler.handle(pendingJob: blocked)
        let queuedSmall = await handler.handle(pendingJob: small)

        XCTAssertTrue(startedRunning)
        XCTAssertTrue(queuedBlocked)
        XCTAssertTrue(queuedSmall)

        let status = await handler.jobStatus
        XCTAssertEqual(status.virtualMachines, 2)
        XCTAssertEqual(status.startedPendingJobs, 1)
        XCTAssertFalse(blocked.didStart)
        XCTAssertTrue(small.didStart)
        await handler.cancelAll()
    }

    func testUnknownResourcesRemainEligible() async {
        let handler = makeHandler(numberOfMachines: 1, cpuLimit: 0, totalMemory: 0)
        let job = makeJob(id: 1, action: .routerStart, cpu: nil, memory: nil)

        let started = await handler.handle(pendingJob: job)

        XCTAssertTrue(started)

        await handler.cancelAll()
    }

    private func makeHandler(
        numberOfMachines: Int = 2,
        cpuLimit: Int = 10,
        totalMemory: Int = 28_672
    ) -> ExecutorJobHandler {
        ExecutorJobHandler(
            routerUrl: nil,
            virtualMachineProvider: BlockingVirtualMachineProvider(),
            logger: TestLogger(),
            numberOfMachines: numberOfMachines,
            cpuLimit: cpuLimit,
            totalMemory: totalMemory
        )
    }

    private func makeJob(
        id: Int,
        action: WorkflowAction,
        cpu: Int?,
        memory: Int?
    ) -> ExecutorPendingJob {
        ExecutorPendingJob(
            workflowJob: WorkflowJob(
                id: id,
                action: action,
                labels: ["tartelet", "image"]
            ),
            imageName: "image",
            netBridgedAdapter: nil,
            isInsecure: false,
            isHeadless: true,
            cpu: cpu,
            memory: memory
        )
    }
}

private final class TestLogger: Logger {
    func info(_: String, parameters _: [String: String]?) {}
    func error(_: String, parameters _: [String: String]?) {}
}

private final class BlockingVirtualMachineProvider: VirtualMachineProvider {
    func createVirtualMachine(
        imageName _: String,
        name: String,
        runnerLabels: String?,
        isInsecure _: Bool,
        cpu _: Int?,
        memory _: Int?
    ) async throws -> VirtualMachine {
        BlockingVirtualMachine(name: name, runnerLabels: runnerLabels)
    }

    func removeVirtualMachines(namePrefix _: String) async throws -> [String] { [] }
    func listVirtualMachines() async throws -> [String] { [] }
    func listVirtualMachineDetails() async throws -> [VirtualMachineListItem] { [] }
    func hostDiskUsage() -> TartDiskUsage? { nil }
    func deleteVirtualMachine(name _: String) async throws {}
    func pullImage(name _: String, isInsecure _: Bool) async throws {}
    func ipAddress(ofVirtualMachineNamed _: String) async throws -> String { "127.0.0.1" }
}

private final class BlockingVirtualMachine: VirtualMachine {
    let name: String
    let runnerLabels: String?
    let canStart = true

    init(name: String, runnerLabels: String?) {
        self.name = name
        self.runnerLabels = runnerLabels
    }

    func start(netBridgedAdapter _: String?, isHeadless _: Bool) async throws {
        try await Task.sleep(for: .seconds(60))
    }

    func setCpu(_: Int) async throws {}
    func setMemory(_: Int) async throws {}
    func clone(named newName: String, isInsecure _: Bool) async throws -> VirtualMachine {
        BlockingVirtualMachine(name: newName, runnerLabels: runnerLabels)
    }
    func delete() async throws {}
    func getIPAddress(shouldUseArpResolver _: Bool) async throws -> String { "127.0.0.1" }
}
