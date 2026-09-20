import Foundation
@testable import TartCommon
import XCTest

final class ResourceCapacityTests: XCTestCase {
    func testMixedSizeJobsFitWithinAggregateCapacity() {
        var status = makeStatus()
        let large = ResourceRequirements(cpu: 7, memory: 24_576)
        let small = ResourceRequirements(cpu: 2, memory: 4_096)

        XCTAssertTrue(status.resourceCapacity.canFit(large))
        status.reserve(large)
        XCTAssertTrue(status.resourceCapacity.canFit(small))
        status.reserve(small)

        XCTAssertEqual(status.cpuUsed, 9)
        XCTAssertEqual(status.memoryUsed, 28_672)
    }

    func testSecondLargeJobDoesNotFit() {
        var status = makeStatus()
        let large = ResourceRequirements(cpu: 7, memory: 24_576)

        status.reserve(large)

        XCTAssertFalse(status.resourceCapacity.canFit(large))
    }

    func testExactCapacityBoundaryFits() {
        let capacity = ResourceCapacity(
            cpuLimit: 10,
            cpuUsed: 3,
            memoryLimit: 28_672,
            memoryUsed: 4_096
        )

        XCTAssertTrue(capacity.canFit(.init(cpu: 7, memory: 24_576)))
        XCTAssertFalse(capacity.canFit(.init(cpu: 8, memory: 24_576)))
        XCTAssertFalse(capacity.canFit(.init(cpu: 7, memory: 24_577)))
    }

    func testUnknownRequirementsPreservePreviousBehavior() {
        let exhausted = ResourceCapacity(
            cpuLimit: 10,
            cpuUsed: 10,
            memoryLimit: 28_672,
            memoryUsed: 28_672
        )

        XCTAssertTrue(exhausted.canFit(.init(cpu: nil, memory: nil)))
    }

    func testOlderStatusPayloadDecodesWithoutDefaults() throws {
        let data = Data(#"{"inProgressJobs":0,"pendingJobs":0,"startedPendingJobs":0,"activeVirtualMachines":0,"virtualMachineLimit":2,"cpuLimit":10,"cpuUsed":0,"totalMemory":28672,"memoryUsed":0}"#.utf8)

        let status = try JSONDecoder().decode(TartHostStatus.self, from: data)

        XCTAssertNil(status.defaultCpu)
        XCTAssertNil(status.defaultMemory)
    }

    private func makeStatus() -> TartHostStatus {
        TartHostStatus(
            inProgressJobs: 0,
            pendingJobs: 0,
            startedPendingJobs: 0,
            activeVirtualMachines: 0,
            virtualMachineLimit: 2,
            cpuLimit: 10,
            cpuUsed: 0,
            totalMemory: 28_672,
            memoryUsed: 0,
            defaultCpu: 5,
            defaultMemory: 14_336
        )
    }
}
