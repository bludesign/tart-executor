import Foundation
@testable import RouterApp
import TartCommon
import XCTest

final class RouterReconciliationTests: XCTestCase {
    private let labels: Set<String> = ["tartelet", "image", "cpu:7", "memory:24576"]

    override func setUp() {
        super.setUp()
        HandlerReconciliationURLProtocol.reset()
    }

    func testMissedJobsDispatchWithOriginalLabelsWithinCapacityAndAreNotDuplicated() async throws {
        let smallLabels: Set<String> = ["tartelet", "image", "cpu:2", "memory:4096"]
        let reconciler = StubReconciler(snapshot: snapshot(jobs: [
            queuedJob(id: 1), queuedJob(id: 2), queuedJob(id: 3, labels: smallLabels)
        ]))
        await reconciler.setStatus(jobStatus(id: 1))
        await reconciler.setStatus(jobStatus(id: 2))
        await reconciler.setStatus(jobStatus(id: 3, labels: smallLabels))
        let handler = await makeHandler(reconciler: reconciler, hosts: [makeHost()])

        await handler.reconcileGitHubJobs()
        await handler.reconcileGitHubJobs()

        let requests = HandlerReconciliationURLProtocol.requests.filter { $0.path == "/router" }
        XCTAssertEqual(requests.count, 2)
        let payloads = try requests.map { try JSONDecoder().decode(WebhookResponse.self, from: $0.body) }
        XCTAssertEqual(Set(payloads.map { $0.workflow_job.id }), [1, 3])
        XCTAssertEqual(payloads.first { $0.workflow_job.id == 1 }?.workflow_job.labels, labels)
        XCTAssertEqual(payloads.first { $0.workflow_job.id == 3 }?.workflow_job.labels, smallLabels)
        XCTAssertTrue(payloads.allSatisfy { $0.repository?.full_name == "owner/repository" })
        let jobs = await handler.jobsSnapshot()
        XCTAssertEqual(jobs.count, 3)
        XCTAssertEqual(jobs.first { $0.id == 1 }?.sentToHost, "executor")
        XCTAssertNil(jobs.first { $0.id == 2 }?.sentToHost)
        XCTAssertEqual(jobs.first { $0.id == 3 }?.sentToHost, "executor")
    }

    func testPartialAndFailedScansDoNotDropTrackedJobs() async {
        let reconciler = StubReconciler(snapshot: snapshot(jobs: [], truncated: true))
        await reconciler.setStatus(jobStatus(id: 1, status: "in_progress"))
        let handler = await makeHandler(reconciler: reconciler)
        _ = await handler.dispatch(id: 1, labels: labels, pinnedHostname: nil, force: false, repository: "owner/repository")

        await handler.reconcileGitHubJobs()
        await reconciler.setScanFailure(true)
        await handler.reconcileGitHubJobs()

        let job = await handler.job(id: 1)
        XCTAssertEqual(job?.action, .inProgress)
        XCTAssertEqual(job?.repository, "owner/repository")
    }

    func testTrackedJobsDoNotConsumeTheMissedJobRecoveryLimit() async {
        let reconciler = StubReconciler(snapshot: snapshot(jobs: (1...41).map { queuedJob(id: $0) }))
        let handler = await makeHandler(reconciler: reconciler)
        for id in 1...41 {
            await reconciler.setStatus(jobStatus(id: id))
            if id <= 40 {
                _ = await handler.dispatch(
                    id: id, labels: labels, pinnedHostname: nil, force: false, repository: "owner/repository"
                )
            }
        }

        await handler.reconcileGitHubJobs()

        let recovered = await handler.job(id: 41)
        let jobs = await handler.jobsSnapshot()
        XCTAssertEqual(recovered?.action, .queued)
        XCTAssertEqual(recovered?.repository, "owner/repository")
        XCTAssertEqual(Set(recovered?.labels ?? []), labels)
        XCTAssertEqual(jobs.count, 41)
    }

    func testOverlappingReconciliationAndUpdatesDoNotDuplicateInFlightDispatch() async {
        let sendStarted = expectation(description: "Recovered job send started")
        let gate = ReconciliationGate(arrival: sendStarted)
        HandlerReconciliationURLProtocol.setSendGate(gate)
        let reconciler = StubReconciler(snapshot: snapshot(jobs: [queuedJob(id: 1)]))
        await reconciler.setStatus(jobStatus(id: 1))
        let handler = await makeHandler(reconciler: reconciler, hosts: [makeHost()])
        let recovery = Task { await handler.reconcileGitHubJobs() }
        await fulfillment(of: [sendStarted], timeout: 3)

        await handler.reconcileGitHubJobs()
        await handler.updateStatus()
        await gate.release()
        await recovery.value

        let job = await handler.job(id: 1)
        XCTAssertEqual(job?.sentToHost, "executor")
        XCTAssertEqual(HandlerReconciliationURLProtocol.requests.filter { $0.path == "/router" }.count, 1)
    }

    func testPermissionFailureLeavesTrackedJobAndDoesNotRecoverUnknownJob() async {
        let reconciler = StubReconciler(snapshot: snapshot(jobs: [queuedJob(id: 2)]))
        await reconciler.setLookupFailure(true)
        let handler = await makeHandler(reconciler: reconciler)
        _ = await handler.dispatch(id: 1, labels: labels, pinnedHostname: nil, force: false, repository: "owner/repository")

        await handler.reconcileGitHubJobs()

        let jobs = await handler.jobsSnapshot()
        XCTAssertEqual(jobs.map(\.id), [1])
        XCTAssertEqual(jobs.first?.action, .queued)
    }

    func testExplicitCompletedStatusRemovesBookkeepingWithoutCancellingRunner() async {
        let reconciler = StubReconciler(snapshot: snapshot(jobs: []))
        await reconciler.setStatus(jobStatus(id: 1, status: "completed"))
        let handler = await makeHandler(reconciler: reconciler, hosts: [makeHost()])
        _ = await handler.dispatch(id: 1, labels: labels, pinnedHostname: nil, force: false, repository: "owner/repository")

        await handler.reconcileGitHubJobs()

        let job = await handler.job(id: 1)
        XCTAssertNil(job)
        XCTAssertEqual(HandlerReconciliationURLProtocol.requests.filter { $0.path == "/router" }.count, 1)
        XCTAssertFalse(HandlerReconciliationURLProtocol.requests.contains { $0.path == "/cancel" })
    }

    func testReconciledCompletionDuringSendDoesNotCancelRunner() async {
        let sendStarted = expectation(description: "Executor send started")
        let gate = ReconciliationGate(arrival: sendStarted)
        HandlerReconciliationURLProtocol.setSendGate(gate)
        let reconciler = StubReconciler(snapshot: snapshot(jobs: []))
        await reconciler.setStatus(jobStatus(id: 1, status: "completed"))
        let handler = await makeHandler(reconciler: reconciler, hosts: [makeHost()])
        let dispatch = Task {
            await handler.dispatch(
                id: 1, labels: labels, pinnedHostname: nil, force: false, repository: "owner/repository"
            )
        }
        await fulfillment(of: [sendStarted], timeout: 3)

        await handler.reconcileGitHubJobs()
        await gate.release()
        _ = await dispatch.value

        let job = await handler.job(id: 1)
        XCTAssertNil(job)
        XCTAssertFalse(HandlerReconciliationURLProtocol.requests.contains { $0.path == "/cancel" })
    }

    func testDelayedQueuedWebhookCannotResurrectReconciledCompletedJob() async {
        let reconciler = StubReconciler(snapshot: snapshot(jobs: []))
        await reconciler.setStatus(jobStatus(id: 1, status: "completed"))
        let handler = await makeHandler(reconciler: reconciler)
        _ = await handler.dispatch(id: 1, labels: labels, pinnedHostname: nil, force: false, repository: "owner/repository")
        await handler.reconcileGitHubJobs()

        await handler.handleJob(job: pendingJob(id: 1, action: .queued))

        let job = await handler.job(id: 1)
        XCTAssertNil(job)
    }

    func testStaleScanDoesNotRecoverJobs() async {
        let reconciler = StubReconciler(snapshot: snapshot(
            jobs: [queuedJob(id: 1)], scannedAt: Date().addingTimeInterval(-300)
        ))
        await reconciler.setStatus(jobStatus(id: 1))
        let handler = await makeHandler(reconciler: reconciler)

        await handler.reconcileGitHubJobs()

        let jobs = await handler.jobsSnapshot()
        let lookups = await reconciler.lookupCount
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertEqual(lookups, 0)
    }

    func testCompletionWhileRecoveryLookupIsInFlightPreventsResurrection() async {
        let lookupStarted = expectation(description: "GitHub lookup started")
        let gate = ReconciliationGate(arrival: lookupStarted)
        let reconciler = StubReconciler(snapshot: snapshot(jobs: [queuedJob(id: 1)]))
        await reconciler.setStatus(jobStatus(id: 1))
        await reconciler.setLookupGate(gate)
        let handler = await makeHandler(reconciler: reconciler)
        let recovery = Task { await handler.reconcileGitHubJobs() }
        await fulfillment(of: [lookupStarted], timeout: 3)

        await handler.handleJob(job: pendingJob(id: 1, action: .completed))
        await gate.release()
        await recovery.value

        let job = await handler.job(id: 1)
        XCTAssertNil(job)
    }

    func testCompletionWhileTrackedLookupIsInFlightPreventsResurrection() async {
        let lookupStarted = expectation(description: "Tracked GitHub lookup started")
        let gate = ReconciliationGate(arrival: lookupStarted)
        let reconciler = StubReconciler(snapshot: snapshot(jobs: []))
        await reconciler.setStatus(jobStatus(id: 1, status: "in_progress"))
        await reconciler.setLookupGate(gate)
        let handler = await makeHandler(reconciler: reconciler)
        _ = await handler.dispatch(id: 1, labels: labels, pinnedHostname: nil, force: false, repository: "owner/repository")
        let recovery = Task { await handler.reconcileGitHubJobs() }
        await fulfillment(of: [lookupStarted], timeout: 3)

        await handler.handleJob(job: pendingJob(id: 1, action: .completed))
        await gate.release()
        await recovery.value

        let job = await handler.job(id: 1)
        XCTAssertNil(job)
    }

    func testRestartLeavesExistingVMOnFullHostWithoutDispatchingDuplicateElsewhere() async {
        let reconciler = StubReconciler(snapshot: snapshot(jobs: [queuedJob(id: 1)]))
        await reconciler.setStatus(jobStatus(id: 1))
        await reconciler.setOwnership(["host-a": [executorJob(id: 1, vmName: "vm-for-1")], "host-b": []])
        HandlerReconciliationURLProtocol.setStatus(hostStatus(activeMachines: 2), hostname: "host-a.test")
        HandlerReconciliationURLProtocol.setStatus(hostStatus(activeMachines: 0), hostname: "host-b.test")
        let handler = await makeHandler(reconciler: reconciler, hosts: [
            makeHost(hostname: "host-a"), makeHost(hostname: "host-b", priority: 1)
        ])

        await handler.reconcileGitHubJobs()

        let job = await handler.job(id: 1)
        XCTAssertNil(job)
        XCTAssertFalse(HandlerReconciliationURLProtocol.requests.contains { $0.path == "/router" })
    }

    func testExecutorPendingRetryWithoutVMDoesNotCreateRunnerOnAnotherHost() async {
        let reconciler = StubReconciler(snapshot: snapshot(jobs: [queuedJob(id: 1)]))
        await reconciler.setStatus(jobStatus(id: 1))
        await reconciler.setOwnership(["host-a": [executorJob(id: 1, vmName: nil)], "host-b": []])
        let handler = await makeHandler(reconciler: reconciler, hosts: [
            makeHost(hostname: "host-a"), makeHost(hostname: "host-b", priority: 1)
        ])

        await handler.reconcileGitHubJobs()

        let job = await handler.job(id: 1)
        XCTAssertNil(job)
        XCTAssertFalse(HandlerReconciliationURLProtocol.requests.contains { $0.path == "/router" })
    }

    func testOwnershipFailureBlocksNewProvisioningButStillReconcilesCompletedJobs() async {
        let reconciler = StubReconciler(snapshot: snapshot(jobs: [queuedJob(id: 2)]))
        await reconciler.setStatus(jobStatus(id: 1, status: "completed"))
        await reconciler.setStatus(jobStatus(id: 2))
        await reconciler.setOwnershipFailure(true)
        let handler = await makeHandler(reconciler: reconciler, hosts: [makeHost()])
        _ = await handler.dispatch(id: 1, labels: labels, pinnedHostname: nil, force: false, repository: "owner/repository")
        let sendsBeforeRecovery = HandlerReconciliationURLProtocol.requests.filter { $0.path == "/router" }.count

        await handler.reconcileGitHubJobs()

        let jobs = await handler.jobsSnapshot()
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertEqual(
            HandlerReconciliationURLProtocol.requests.filter { $0.path == "/router" }.count, sendsBeforeRecovery
        )
        XCTAssertFalse(HandlerReconciliationURLProtocol.requests.contains { $0.path == "/cancel" })
    }

    func testMissedInProgressEventTransfersVMAttributionAndDispatchesDisplacedJob() async {
        let reconciler = StubReconciler(snapshot: snapshot(jobs: []))
        let handler = await makeHandler(reconciler: reconciler, hosts: [
            makeHost(hostname: "host-a"), makeHost(hostname: "host-b", priority: 1)
        ])
        HandlerReconciliationURLProtocol.setStatus(hostStatus(activeMachines: 0), hostname: "host-a.test")
        HandlerReconciliationURLProtocol.setStatus(hostStatus(activeMachines: 2), hostname: "host-b.test")
        _ = await handler.dispatch(id: 1, labels: labels, pinnedHostname: nil, force: false, repository: "owner/repository")
        HandlerReconciliationURLProtocol.setStatus(hostStatus(activeMachines: 2), hostname: "host-a.test")
        _ = await handler.dispatch(id: 2, labels: labels, pinnedHostname: nil, force: false, repository: "owner/repository")
        await reconciler.setStatus(jobStatus(id: 1))
        await reconciler.setStatus(jobStatus(id: 2, status: "in_progress", runnerName: "vm-for-1"))
        await reconciler.setOwnership(["host-a": [executorJob(id: 1, vmName: "vm-for-1")], "host-b": []])
        HandlerReconciliationURLProtocol.setStatus(hostStatus(activeMachines: 0), hostname: "host-b.test")

        await handler.reconcileGitHubJobs()

        let displaced = await handler.job(id: 1)
        let running = await handler.job(id: 2)
        XCTAssertEqual(displaced?.sentToHost, "host-b")
        XCTAssertEqual(running?.sentToHost, "host-a")
        XCTAssertEqual(running?.action, .inProgress)
        let sends = HandlerReconciliationURLProtocol.requests.filter { $0.path == "/router" }
        XCTAssertEqual(sends.map(\.hostname), ["host-a.test", "host-b.test"])
    }

}

private extension RouterReconciliationTests {
    func executorJob(id: Int, vmName: String?) -> ExecutorJobDTO {
        ExecutorJobDTO(
            id: id, action: .queued, state: .pending, labels: labels.sorted(), didStart: vmName != nil,
            cpu: 7, memory: 24_576, imageName: "image", vmName: vmName,
            vmUUID: nil, queuedAt: Date(), startedAt: Date()
        )
    }

    func hostStatus(activeMachines: Int) -> TartHostStatus {
        TartHostStatus(
            inProgressJobs: 0, pendingJobs: 0, startedPendingJobs: 0,
            activeVirtualMachines: activeMachines, virtualMachineLimit: 2,
            cpuLimit: 10, cpuUsed: 0, totalMemory: 28_672, memoryUsed: 0
        )
    }

    func makeHandler(reconciler: StubReconciler, hosts: [TartHost] = []) async -> RouterJobHandler {
        await reconciler.setDefaultOwnership(hostnames: hosts.map(\.hostname))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HandlerReconciliationURLProtocol.self]
        return RouterJobHandler(
            hosts: hosts,
            logger: ReconciliationLogger(),
            reconciler: reconciler,
            runnerLabels: ["tartelet"],
            session: URLSession(configuration: configuration)
        )
    }

    func makeHost(hostname: String = "executor", priority: Int = 0) -> TartHost {
        TartHost(
            hostname: hostname, url: URL(string: "http://\(hostname).test:3250")!,
            priority: priority, cpuLimit: 10, memoryLimit: 28_672
        )
    }

    func pendingJob(id: Int, action: WorkflowAction) -> RouterPendingJob {
        RouterPendingJob(
            workflowJob: WorkflowJob(id: id, action: action, labels: labels),
            headers: [:], bodyData: Data(), pinnedHostname: nil, repository: "owner/repository"
        )
    }

    func jobStatus(
        id: Int, status: String = "queued", labels override: Set<String>? = nil, runnerName: String? = nil
    ) -> GitHubJobStatusDTO {
        GitHubJobStatusDTO(
            id: id, repository: "owner/repository", status: status,
            labels: (override ?? labels).sorted(), runnerName: runnerName
        )
    }

    func queuedJob(id: Int, labels override: Set<String>? = nil) -> GitHubQueuedJobDTO {
        GitHubQueuedJobDTO(
            id: id, runId: 100, name: "Build", workflowName: nil, repository: "owner/repository",
            htmlUrl: nil, labels: (override ?? labels).sorted(), createdAt: Date().addingTimeInterval(Double(id) - 300),
            matchesRunnerLabels: true, labelMismatchReason: nil, imageName: "image", cpu: nil, memory: nil
        )
    }

    func snapshot(
        jobs: [GitHubQueuedJobDTO], truncated: Bool = false, scannedAt: Date = Date()
    ) -> GitHubQueuedJobsResponse {
        GitHubQueuedJobsResponse(
            hostname: "executor", jobs: jobs, scannedAt: scannedAt, repositoriesScanned: 1,
            truncated: truncated, warnings: truncated ? ["Rate limited"] : [],
            rateLimitRemaining: nil, rateLimitResetAt: nil
        )
    }
}
