import Foundation
@testable import RouterApp
import TartCommon
import XCTest

final class RouterObservationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ObservationURLProtocol.reset()
    }

    func testFanoutPreservesNormalizedMetadataDatesAndManagementAuthentication() async throws {
        let handler = makeHandler()
        let context = makeContext()
        let queued = GitHubJobContext(workflowJobId: "43", status: "queued", runnerName: "waiting-runner")
        let missingRunner = GitHubJobContext(workflowJobId: "44", status: "completed")
        let emptyRunner = GitHubJobContext(workflowJobId: "45", status: "in_progress", runnerName: "")

        await handler.broadcastObservations([queued, context, missingRunner, emptyRunner])

        let requests = ObservationURLProtocol.requests
        XCTAssertEqual(Set(requests.compactMap { $0.url?.host }), ["primary.test", "secondary.test"])
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/github/job-observations")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer executor-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertLessThanOrEqual(request.timeoutInterval, 5)
            let body = try XCTUnwrap(request.httpBody)
            let payload = try JSONDecoder.api.decode(GitHubJobObservationsRequest.self, from: body)
            XCTAssertEqual(payload.jobs, [context])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]])
            XCTAssertEqual(jobs.first?["observedAt"] as? String, "2025-10-29T16:00:00Z")
        }
        let jobs = await handler.jobsSnapshot()
        XCTAssertTrue(jobs.isEmpty)
    }

    func testCompletedObservationAndFailedHostDoNotChangeSchedulerState() async throws {
        let handler = makeHandler()
        await handler.seedObservationTestJob()
        ObservationURLProtocol.setStatus(503, host: "primary.test")
        let before = await handler.jobsSnapshot()
        let completedBefore = await handler.completedJobs
        var context = makeContext()
        context.status = "completed"
        context.conclusion = "success"

        await handler.broadcastObservations([context])

        let after = await handler.jobsSnapshot()
        let completedAfter = await handler.completedJobs
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.action), before.map(\.action))
        XCTAssertEqual(after.map(\.sentToHost), before.map(\.sentToHost))
        XCTAssertEqual(after.map(\.sentAt), before.map(\.sentAt))
        XCTAssertEqual(completedAfter, completedBefore)
        XCTAssertEqual(ObservationURLProtocol.requests.count, 2)
        XCTAssertTrue(ObservationURLProtocol.requests.allSatisfy { request in
            request.url?.path == "/api/v1/github/job-observations"
        })
    }

    func testObservationRefreshConsumesRunnerSidecarWithoutDispatchingQueuedJobs() async throws {
        let context = makeContext()
        let queued = GitHubQueuedJobDTO(
            id: 99, runId: 7, name: "Waiting", workflowName: "CI", repository: "owner/repo",
            htmlUrl: nil, labels: ["tartelet", "image"], createdAt: Date(),
            matchesRunnerLabels: true, labelMismatchReason: nil, imageName: "image", cpu: nil, memory: nil
        )
        let snapshot = GitHubQueuedJobsResponse(
            hostname: "source", jobs: [queued], scannedAt: Date(), repositoriesScanned: 1,
            truncated: true, warnings: ["Partial scan"], rateLimitRemaining: 900,
            rateLimitResetAt: nil, runnerJobs: [context]
        )
        let source = StubReconciler(snapshot: snapshot)
        let handler = makeHandler()

        await handler.refreshRunnerObservations(using: source)

        let requests = ObservationURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let payload = try JSONDecoder.api.decode(
                GitHubJobObservationsRequest.self, from: XCTUnwrap(request.httpBody)
            )
            XCTAssertEqual(payload.jobs, [context])
        }
        let tracked = await handler.jobsSnapshot()
        let lookupCount = await source.lookupCount
        XCTAssertTrue(tracked.isEmpty)
        XCTAssertEqual(lookupCount, 0)
    }

    func testLargeObservationBatchFitsExecutorRequestLimit() async throws {
        let contexts = (1...1_001).map { id in
            GitHubJobContext(workflowJobId: String(id), status: "in_progress", runnerName: "runner-\(id)")
        }

        await makeHandler().broadcastObservations(contexts)

        let requests = ObservationURLProtocol.requests
        XCTAssertEqual(requests.count, 4)
        for host in ["primary.test", "secondary.test"] {
            let batches = try requests.filter { $0.url?.host == host }.map { request in
                try JSONDecoder.api.decode(GitHubJobObservationsRequest.self, from: XCTUnwrap(request.httpBody))
            }
            XCTAssertEqual(batches.map { $0.jobs.count }.sorted(), [1, 1_000])
            XCTAssertEqual(Set(batches.flatMap(\.jobs).map(\.workflowJobId)).count, 1_001)
        }
    }

    private func makeHandler() -> RouterJobHandler {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObservationURLProtocol.self]
        let hosts = ["primary", "secondary"].enumerated().map { index, name in
            TartHost(
                hostname: name, url: URL(string: "http://\(name).test:3250")!,
                priority: index, cpuLimit: nil, memoryLimit: nil
            )
        }
        return RouterJobHandler(
            hosts: hosts, logger: ReconciliationLogger(), runnerLabels: ["tartelet"],
            session: URLSession(configuration: configuration), executorApiToken: "executor-secret"
        )
    }

    private func makeContext() -> GitHubJobContext {
        let date = Date(timeIntervalSince1970: 1_761_753_600)
        return GitHubJobContext(
            workflowJobId: "42", workflowRunId: "7", repository: "owner/repo", name: "Build iOS",
            workflowName: "CI", htmlUrl: "https://github.com/owner/repo/actions/runs/7/job/42",
            runUrl: "https://github.com/owner/repo/actions/runs/7", runTitle: "Build feature",
            runNumber: 8, runAttempt: 2, event: "push", actor: "octocat",
            headBranch: "feature/test", headSha: "abc123", status: "in_progress",
            runnerName: "tart-executor-99-unique-runner", createdAt: date.addingTimeInterval(-60),
            startedAt: date, observedAt: date, source: "github_api", warnings: []
        )
    }
}

private extension RouterJobHandler {
    func seedObservationTestJob() {
        let workflowJob = WorkflowJob(id: 42, action: .queued, labels: ["tartelet", "image"])
        let job = RouterPendingJob(
            workflowJob: workflowJob, headers: [:], bodyData: Data(), pinnedHostname: nil,
            repository: "owner/repo"
        )
        job.sentToHost = hosts.first
        jobs[job.id] = job
        completedJobs[1] = Date(timeIntervalSince1970: 1_761_753_500)
    }
}

private final class ObservationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var capturedRequests = [URLRequest]()
    private static var statuses = [String: Int]()

    static var requests: [URLRequest] { lock.withLock { capturedRequests } }

    static func reset() {
        lock.withLock {
            capturedRequests = []
            statuses = [:]
        }
    }

    static func setStatus(_ status: Int, host: String) { lock.withLock { statuses[host] = status } }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil { captured.httpBody = readBodyStream() }
        let status = Self.lock.withLock {
            Self.capturedRequests.append(captured)
            return Self.statuses[captured.url?.host ?? ""] ?? 200
        }
        guard let url = captured.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    private func readBodyStream() -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    override func stopLoading() {}
}
