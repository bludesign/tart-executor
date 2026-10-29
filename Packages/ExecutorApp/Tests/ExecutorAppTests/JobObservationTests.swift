@testable import ExecutorApp
import Foundation
import LoggingDomain
import TartCommon
import VirtualMachineDomain
import XCTest

final class JobObservationTests: XCTestCase {
    func testManualDispatchRetainsCreationContextBeforeAnyWebhook() async {
        let handler = makeHandler()
        let context = GitHubJobContext(workflowJobId: "7", repository: "owner/repo", name: "Manual build")
        let pending = ExecutorPendingJob(
            workflowJob: .init(id: 7, action: .queued, labels: ["runner", "image"], github: context),
            imageName: "image", netBridgedAdapter: nil, isInsecure: false, isHeadless: true, cpu: 2, memory: 4_096
        )
        let createdFor = await handler.dispatchAndReadCreation(pending)
        XCTAssertEqual(createdFor, context)
        await handler.cancelAll()
    }

    func testSwappedAssignmentsKeepCreationIdentityAndDoNotChangeScheduler() async {
        let handler = makeHandler()
        await handler.seedObservationVM(id: 1, name: "vm-one")
        await handler.seedObservationVM(id: 2, name: "vm-two")
        let before = await handler.jobsSnapshot()

        await handler.observeJob(context(id: 2, runner: "vm-one"))
        await handler.observeJob(context(id: 1, runner: "vm-two"))

        let first = await handler.attribution(for: "vm-one")
        let second = await handler.attribution(for: "vm-two")
        XCTAssertEqual(first.createdFor?.workflowJobId, "1")
        XCTAssertEqual(first.assigned?.workflowJobId, "2")
        XCTAssertEqual(second.createdFor?.workflowJobId, "2")
        XCTAssertEqual(second.assigned?.workflowJobId, "1")
        let after = await handler.jobsSnapshot()
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(before.map(\.state), after.map(\.state))
        XCTAssertEqual(before.map(\.vmName), after.map(\.vmName))
    }

    func testCompletedAssignmentSurvivesLateProgressAndUnknownObservations() async {
        let handler = makeHandler()
        await handler.seedObservationVM(id: 1, name: "vm-one")
        await handler.observeJob(context(id: 2, runner: "vm-one", status: "completed", time: 20))
        await handler.observeJob(context(id: 2, runner: "vm-one", time: 30))
        await handler.observeJob(context(id: 3, runner: "vm-one", time: 40))
        await handler.observeJob(context(id: 4, runner: "not-a-registered-vm", time: 50))
        let attribution = await handler.attribution(for: "vm-one")
        XCTAssertEqual(attribution.assigned?.workflowJobId, "2")
        XCTAssertEqual(attribution.assigned?.status, "completed")
        let jobs = await handler.metadataJobs()
        XCTAssertFalse(jobs.contains { $0.workflowJobId == "4" })
    }

    func testVMNameJobIDIsNotEvidenceOfAssignmentAndCleanupDropsObservation() async {
        let handler = makeHandler()
        let uuid = await handler.seedObservationVM(id: 1, name: "tart-executor-1-test")
        await handler.observeJob(context(id: 1, runner: nil))
        let before = await handler.attribution(for: "tart-executor-1-test")
        XCTAssertNil(before.assigned)
        await handler.observeJob(context(id: 2, runner: "tart-executor-1-test"))
        await handler.remove(uuid: uuid)
        // A failed cleanup can leave the VM present after its task has ended.
        await handler.confirmInventory(names: ["tart-executor-1-test"])
        let lingering = await handler.attribution(for: "tart-executor-1-test")
        XCTAssertEqual(lingering.assigned?.workflowJobId, "2")
        await handler.confirmInventory(names: [])
        let after = await handler.attribution(for: "tart-executor-1-test")
        XCTAssertNil(after.createdFor)
        XCTAssertNil(after.assigned)
    }

    private func context(id: Int, runner: String?, status: String = "in_progress", time: TimeInterval = 10) -> GitHubJobContext {
        .init(
            workflowJobId: String(id), repository: "owner/repo", name: "Build \(id)",
            status: status, runnerName: runner, observedAt: Date(timeIntervalSince1970: time), source: "webhook"
        )
    }

    private func makeHandler() -> ExecutorJobHandler {
        ExecutorJobHandler(
            routerUrl: nil, virtualMachineProvider: ObservationProvider(), logger: ObservationLogger(),
            numberOfMachines: 2, cpuLimit: 8, totalMemory: 16_384
        )
    }
}

private extension ExecutorJobHandler {
    func dispatchAndReadCreation(_ pending: ExecutorPendingJob) -> GitHubJobContext? {
        guard case let .started(name) = dispatch(pendingJob: pending, force: false) else { return nil }
        return attribution(for: name).createdFor
    }

    @discardableResult
    func seedObservationVM(id: Int, name: String) -> UUID {
        let uuid = UUID()
        createdJobIDs[name] = id
        activeJobs[uuid] = ActiveJob(
            jobId: id, labels: ["runner", "image"], task: Task {}, cpu: 2, memory: 4_096,
            vmName: name, startedAt: Date(), imageName: "image"
        )
        rememberContext(.init(workflowJobId: String(id), repository: "owner/repo", name: "Created \(id)"))
        return uuid
    }

}

private final class ObservationLogger: Logger {
    func info(_: String, parameters _: [String: String]?) {}
    func error(_: String, parameters _: [String: String]?) {}
}

private final class ObservationProvider: VirtualMachineProvider {
    func createVirtualMachine(
        imageName _: String, name _: String, runnerLabels _: String?, isInsecure _: Bool, cpu _: Int?, memory _: Int?
    ) async throws -> VirtualMachine { throw CocoaError(.featureUnsupported) }
    func removeVirtualMachines(namePrefix _: String) async throws -> [String] { [] }
    func listVirtualMachines() async throws -> [String] { [] }
    func listVirtualMachineDetails() async throws -> [VirtualMachineListItem] { [] }
    func hostDiskUsage() -> TartDiskUsage? { nil }
    func deleteVirtualMachine(name _: String) async throws {}
    func pullImage(name _: String, isInsecure _: Bool) async throws {}
    func ipAddress(ofVirtualMachineNamed _: String) async throws -> String { "" }
}
