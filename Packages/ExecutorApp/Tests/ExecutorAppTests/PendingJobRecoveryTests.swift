@testable import ExecutorApp
import Foundation
import LoggingDomain
import TartCommon
import VirtualMachineDomain
import XCTest

final class PendingJobRecoveryTests: XCTestCase {
    func testCreationFailureStartupFailureAndEarlyStopRetryAfterBackoff() async throws {
        for failure in [RecoveryVMProvider.FirstAttempt.creationFailure, .startupFailure, .earlyStop] {
            let provider = RecoveryVMProvider(firstAttempt: failure)
            let retry = RetryGate()
            let handler = makeHandler(provider: provider, retry: retry)
            let job = makeJob(id: 1)

            _ = await handler.handle(pendingJob: job)
            try await eventually { await retry.waiterCount == 1 }

            let status = await handler.jobStatus
            XCTAssertEqual(status.virtualMachines, 0)
            XCTAssertEqual(status.pendingJobs, 1)
            XCTAssertFalse(job.didStart)
            let attemptsBeforeRetry = await provider.attempts.jobIds
            XCTAssertEqual(attemptsBeforeRetry, [1])

            await retry.release()
            try await eventually { await provider.attempts.jobIds.count == 2 }
            let attemptsAfterRetry = await provider.attempts.jobIds
            XCTAssertEqual(attemptsAfterRetry, [1, 1])
            await handler.cancelAll()
        }
    }

    func testOtherQueuedWorkRunsWhileFailedJobBacksOff() async throws {
        let provider = RecoveryVMProvider(firstAttempt: .creationFailure)
        let retry = RetryGate()
        let handler = makeHandler(provider: provider, retry: retry)
        let failedJob = makeJob(id: 1)

        _ = await handler.handle(pendingJob: failedJob)
        _ = await handler.handle(pendingJob: makeJob(id: 2))
        try await eventually { await provider.attempts.jobIds.count == 2 }
        try await eventually { await retry.waiterCount == 1 }
        await retry.release()
        try await eventually { await handler.job(id: 1)?.didStart == false }

        let attemptsWhileOccupied = await provider.attempts.jobIds
        XCTAssertEqual(attemptsWhileOccupied, [1, 2])
        _ = await handler.cancel(jobId: 2)
        try await eventually { await provider.attempts.jobIds.count == 3 }
        let attemptsAfterCapacityFrees = await provider.attempts.jobIds
        XCTAssertEqual(attemptsAfterCapacityFrees, [1, 2, 1])
        await handler.cancelAll()
    }

    func testCompletionProgressAndCancellationInvalidateDelayedRetry() async throws {
        for action in RetryInvalidation.allCases {
            let provider = RecoveryVMProvider(firstAttempt: .creationFailure)
            let retry = RetryGate()
            let handler = makeHandler(provider: provider, retry: retry)
            _ = await handler.handle(pendingJob: makeJob(id: 1))
            try await eventually { await retry.waiterCount == 1 }

            switch action {
            case .completed:
                _ = await handler.handle(pendingJob: makeJob(id: 1, action: .completed))
            case .inProgress:
                _ = await handler.handle(pendingJob: makeJob(id: 1, action: .inProgress))
            case .cancel:
                _ = await handler.cancel(jobId: 1)
            case .cancelAll:
                await handler.cancelAll()
            case .cancelLabels:
                let cancelledCount = await handler.cancelJobsByLabels(["tartelet", "image"])
                XCTAssertEqual(cancelledCount, 1)
                let cancelledJob = await handler.job(id: 1)
                XCTAssertNil(cancelledJob)
            }
            await retry.release()
            try await Task.sleep(for: .milliseconds(20))

            let attempts = await provider.attempts.jobIds
            XCTAssertEqual(attempts, [1], "Retry survived \(action)")
            let status = await handler.jobStatus
            XCTAssertEqual(status.virtualMachines, 0)
            await handler.cancelAll()
        }
    }

    func testCancellingRunningVMDoesNotRetryDuringBothCleanupPaths() async throws {
        let provider = RecoveryVMProvider(firstAttempt: .blocking)
        let retry = RetryGate()
        let handler = makeHandler(provider: provider, retry: retry)
        _ = await handler.handle(pendingJob: makeJob(id: 1))
        try await eventually { await provider.attempts.jobIds.count == 1 }
        await handler.cancelAll()
        try await eventually { await handler.jobStatus.virtualMachines == 0 }
        try await Task.sleep(for: .milliseconds(20))

        let waiterCount = await retry.waiterCount
        let attempts = await provider.attempts.jobIds
        XCTAssertEqual(waiterCount, 0)
        XCTAssertEqual(attempts, [1])
    }

    func testLabelCancellationCountsPendingAndActiveJobsOnce() async throws {
        let provider = RecoveryVMProvider(firstAttempt: .blocking)
        let retry = RetryGate()
        let handler = makeHandler(provider: provider, retry: retry)
        _ = await handler.handle(pendingJob: makeJob(id: 1))
        _ = await handler.handle(pendingJob: makeJob(id: 2))
        try await eventually { await provider.attempts.jobIds.count == 1 }

        let cancelledCount = await handler.cancelJobsByLabels(["tartelet", "image"])
        let status = await handler.jobStatus

        XCTAssertEqual(cancelledCount, 2)
        XCTAssertEqual(status.pendingJobs, 0)
        try await eventually { await handler.jobStatus.virtualMachines == 0 }
        let attempts = await provider.attempts.jobIds
        XCTAssertEqual(attempts, [1])
    }

    func testStartingSamePendingJobCannotCreateDuplicateVM() async throws {
        let provider = RecoveryVMProvider(firstAttempt: .blocking)
        let retry = RetryGate()
        let handler = makeHandler(provider: provider, retry: retry)
        let job = makeJob(id: 1)

        let firstName = await handler.start(pendingJob: job)
        let duplicateName = await handler.start(pendingJob: job)
        try await eventually { await provider.attempts.jobIds.count == 1 }
        let status = await handler.jobStatus

        XCTAssertEqual(duplicateName, firstName)
        XCTAssertEqual(status.virtualMachines, 1)
        await handler.cancelAll()
    }

    private func makeHandler(provider: RecoveryVMProvider, retry: RetryGate) -> ExecutorJobHandler {
        ExecutorJobHandler(
            routerUrl: nil,
            virtualMachineProvider: provider,
            logger: RecoveryLogger(),
            numberOfMachines: 1,
            cpuLimit: 10,
            totalMemory: 28_672
        ) {
            await retry.wait()
        }
    }

    private func makeJob(id: Int, action: WorkflowAction = .queued) -> ExecutorPendingJob {
        ExecutorPendingJob(
            workflowJob: WorkflowJob(id: id, action: action, labels: ["tartelet", "image"]),
            imageName: "image",
            netBridgedAdapter: nil,
            isInsecure: false,
            isHeadless: true,
            cpu: 2,
            memory: 4_096
        )
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for executor state")
                throw RecoveryError.timedOut
            }
            await Task.yield()
        }
    }
}

private enum RetryInvalidation: CaseIterable {
    case completed, inProgress, cancel, cancelAll, cancelLabels
}

private enum RecoveryError: Error {
    case failed, timedOut
}

private actor RetryGate {
    private var waiters = [CheckedContinuation<Void, Never>]()
    var waiterCount: Int { waiters.count }

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        let waiting = waiters
        waiters.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private final class RecoveryLogger: Logger {
    func info(_: String, parameters _: [String: String]?) {}
    func error(_: String, parameters _: [String: String]?) {}
}

private actor RecoveryAttempts {
    private(set) var jobIds = [Int]()

    func record(name: String) -> Bool {
        let jobId = Int(name.split(separator: "-")[2]) ?? -1
        jobIds.append(jobId)
        return jobIds.count == 1
    }
}

private final class RecoveryVMProvider: VirtualMachineProvider {
    enum FirstAttempt {
        case creationFailure, startupFailure, earlyStop, blocking
    }

    let attempts = RecoveryAttempts()
    private let firstAttempt: FirstAttempt

    init(firstAttempt: FirstAttempt) {
        self.firstAttempt = firstAttempt
    }

    func createVirtualMachine(
        imageName _: String,
        name: String,
        runnerLabels: String?,
        isInsecure _: Bool,
        cpu _: Int?,
        memory _: Int?
    ) async throws -> VirtualMachine {
        let isFirstAttempt = await attempts.record(name: name)
        if isFirstAttempt, firstAttempt == .creationFailure {
            throw RecoveryError.failed
        }
        return RecoveryVM(
            name: name,
            runnerLabels: runnerLabels,
            outcome: isFirstAttempt ? firstAttempt : .blocking
        )
    }

    func removeVirtualMachines(namePrefix _: String) async throws -> [String] { [] }
    func listVirtualMachines() async throws -> [String] { [] }
    func listVirtualMachineDetails() async throws -> [VirtualMachineListItem] { [] }
    func hostDiskUsage() -> TartDiskUsage? { nil }
    func deleteVirtualMachine(name _: String) async throws {}
    func pullImage(name _: String, isInsecure _: Bool) async throws {}
    func ipAddress(ofVirtualMachineNamed _: String) async throws -> String { "127.0.0.1" }
}

private struct RecoveryVM: VirtualMachine {
    let name: String
    let runnerLabels: String?
    let outcome: RecoveryVMProvider.FirstAttempt
    let canStart = true

    func start(netBridgedAdapter _: String?, isHeadless _: Bool) async throws {
        switch outcome {
        case .creationFailure, .startupFailure:
            throw RecoveryError.failed
        case .earlyStop:
            return
        case .blocking:
            try await Task.sleep(for: .seconds(60))
        }
    }

    func setCpu(_: Int) async throws {}
    func setMemory(_: Int) async throws {}
    func clone(named _: String, isInsecure _: Bool) async throws -> VirtualMachine { self }
    func delete() async throws {}
    func getIPAddress(shouldUseArpResolver _: Bool) async throws -> String { "127.0.0.1" }
}
