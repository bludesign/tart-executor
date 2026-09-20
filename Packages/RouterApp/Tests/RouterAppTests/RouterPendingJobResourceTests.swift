import Foundation
@testable import RouterApp
import TartCommon
import XCTest

final class RouterPendingJobResourceTests: XCTestCase {
    func testExecutorDefaultsAreUsedWhenLabelsAreAbsent() {
        let job = makeJob(labels: ["tartelet", "image"])
        let requirements = job.resourceRequirements(for: makeStatus(defaultCpu: 5, defaultMemory: 14_336))

        XCTAssertEqual(requirements, .init(cpu: 5, memory: 14_336))
    }

    func testExplicitLabelsOverrideExecutorDefaults() {
        let job = makeJob(labels: ["tartelet", "image", "cpu:7", "memory:24576"])
        let requirements = job.resourceRequirements(for: makeStatus(defaultCpu: 5, defaultMemory: 14_336))

        XCTAssertEqual(requirements, .init(cpu: 7, memory: 24_576))
    }

    func testRouterLimitsRemainPerJobMaximums() {
        let job = makeJob(labels: ["tartelet", "image", "cpu:7", "memory:24576"])
        let requirements = job.resourceRequirements(for: makeStatus())
        let eligible = makeHost(hostname: "eligible", cpuLimit: 10, memoryLimit: 28_672)
        let cpuLimited = makeHost(hostname: "cpu-limited", cpuLimit: 5, memoryLimit: 28_672)
        let memoryLimited = makeHost(hostname: "memory-limited", cpuLimit: 10, memoryLimit: 14_336)

        XCTAssertTrue(job.hostCanRun(eligible, requirements: requirements))
        XCTAssertFalse(job.hostCanRun(cpuLimited, requirements: requirements))
        XCTAssertFalse(job.hostCanRun(memoryLimited, requirements: requirements))
    }

    func testPinnedHostRestrictionIsPreserved() {
        let job = makeJob(labels: ["tartelet", "image"], pinnedHostname: "server-3")
        let requirements = job.resourceRequirements(for: makeStatus())

        XCTAssertTrue(job.hostCanRun(makeHost(hostname: "server-3"), requirements: requirements))
        XCTAssertFalse(job.hostCanRun(makeHost(hostname: "server-4"), requirements: requirements))
    }

    private func makeJob(labels: Set<String>, pinnedHostname: String? = nil) -> RouterPendingJob {
        RouterPendingJob(
            workflowJob: WorkflowJob(id: 1, action: .queued, labels: labels),
            headers: [:],
            bodyData: Data(),
            pinnedHostname: pinnedHostname
        )
    }

    private func makeStatus(defaultCpu: Int? = nil, defaultMemory: Int? = nil) -> TartHostStatus {
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
            defaultCpu: defaultCpu,
            defaultMemory: defaultMemory
        )
    }

    private func makeHost(
        hostname: String,
        cpuLimit: Int? = nil,
        memoryLimit: Int? = nil
    ) -> TartHost {
        TartHost(
            hostname: hostname,
            url: URL(string: "http://127.0.0.1:3250")!,
            priority: 1,
            cpuLimit: cpuLimit,
            memoryLimit: memoryLimit
        )
    }
}
