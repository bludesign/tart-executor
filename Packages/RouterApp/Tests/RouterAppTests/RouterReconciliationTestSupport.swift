import Foundation
import LoggingDomain
@testable import RouterApp
import TartCommon
import XCTest

actor StubReconciler: RouterGitHubReconciling {
    private let snapshot: GitHubQueuedJobsResponse
    private var statuses = [Int: GitHubJobStatusDTO]()
    private var scanFails = false
    private var lookupFails = false
    private var ownershipFails = false
    private var ownership: [String: [ExecutorJobDTO]]?
    private var lookupGate: ReconciliationGate?
    private(set) var lookupCount = 0

    init(snapshot: GitHubQueuedJobsResponse) { self.snapshot = snapshot }

    func setStatus(_ status: GitHubJobStatusDTO) { statuses[status.id] = status }
    func setScanFailure(_ fail: Bool) { scanFails = fail }
    func setLookupFailure(_ fail: Bool) { lookupFails = fail }
    func setLookupGate(_ gate: ReconciliationGate) { lookupGate = gate }
    func setOwnership(_ jobs: [String: [ExecutorJobDTO]]) { ownership = jobs }
    func setOwnershipFailure(_ fail: Bool) { ownershipFails = fail }
    func setDefaultOwnership(hostnames: [String]) {
        if ownership == nil { ownership = Dictionary(uniqueKeysWithValues: hostnames.map { ($0, []) }) }
    }

    func executorJobs() async throws -> [String: [ExecutorJobDTO]] {
        if ownershipFails { throw ReconciliationTestError.httpStatus(503) }
        return ownership ?? [:]
    }

    func queuedJobs() async throws -> GitHubQueuedJobsResponse {
        if scanFails { throw ReconciliationTestError.httpStatus(403) }
        return snapshot
    }

    func job(id: Int, repository _: String) async throws -> GitHubJobStatusDTO {
        lookupCount += 1
        if lookupFails { throw ReconciliationTestError.httpStatus(403) }
        guard let status = statuses[id] else { throw ReconciliationTestError.httpStatus(404) }
        if let gate = lookupGate {
            lookupGate = nil
            await gate.wait()
        }
        return status
    }
}

enum ReconciliationTestError: Error {
    case httpStatus(Int)
}

actor ReconciliationGate {
    private let arrival: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(arrival: XCTestExpectation) { self.arrival = arrival }

    func wait() async {
        arrival.fulfill()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class ReconciliationLogger: Logger {
    func info(_: String, parameters _: [String: String]?) {}
    func error(_: String, parameters _: [String: String]?) {}
}

final class HandlerReconciliationURLProtocol: URLProtocol {
    struct CapturedRequest {
        let hostname: String
        let path: String
        let body: Data
    }

    private static let lock = NSLock()
    private static var capturedRequests = [CapturedRequest]()
    private static var sendGate: ReconciliationGate?
    private static var activeMachines = 0
    private static var cpuUsed = 0
    private static var memoryUsed = 0
    private static var hostStatuses = [String: TartHostStatus]()

    static var requests: [CapturedRequest] { lock.withLock { capturedRequests } }

    static func reset() {
        lock.withLock {
            capturedRequests = []
            sendGate = nil
            activeMachines = 0
            cpuUsed = 0
            memoryUsed = 0
            hostStatuses = [:]
        }
    }

    static func setSendGate(_ gate: ReconciliationGate) { lock.withLock { sendGate = gate } }
    static func setStatus(_ status: TartHostStatus, hostname: String) {
        lock.withLock { hostStatuses[hostname] = status }
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? readBodyStream()
        let gate = Self.lock.withLock { () -> ReconciliationGate? in
            let hostname = request.url?.host ?? ""
            Self.capturedRequests.append(.init(hostname: hostname, path: request.url?.path ?? "", body: body))
            guard request.url?.path == "/router" else { return nil }
            if let payload = try? JSONDecoder().decode(WebhookResponse.self, from: body) {
                let job = WorkflowJob(id: payload.workflow_job.id, action: .queued, labels: payload.workflow_job.labels)
                if var status = Self.hostStatuses[hostname] {
                    status.activeVirtualMachines += 1
                    status.reserve(.init(cpu: job.cpu, memory: job.memory))
                    Self.hostStatuses[hostname] = status
                } else {
                    Self.activeMachines += 1
                    Self.cpuUsed += job.cpu ?? 0
                    Self.memoryUsed += job.memory ?? 0
                }
            }
            defer { Self.sendGate = nil }
            return Self.sendGate
        }
        if let gate {
            Task {
                await gate.wait()
                respond()
            }
        } else {
            respond()
        }
    }

    private func readBodyStream() -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }

    private func respond() {
        guard let url = request.url else { return }
        let data: Data
        if url.path == "/status" {
            let status = Self.lock.withLock {
                Self.hostStatuses[url.host ?? ""] ?? TartHostStatus(
                    inProgressJobs: 0, pendingJobs: 0, startedPendingJobs: 0,
                    activeVirtualMachines: Self.activeMachines, virtualMachineLimit: 2,
                    cpuLimit: 10, cpuUsed: Self.cpuUsed, totalMemory: 28_672, memoryUsed: Self.memoryUsed
                )
            }
            do {
                data = try JSONEncoder().encode(status)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        } else {
            data = Data()
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
