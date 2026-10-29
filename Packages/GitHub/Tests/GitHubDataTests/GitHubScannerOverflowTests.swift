import Foundation
@testable import GitHubData
import GitHubDomain
import LoggingDomain
import XCTest

final class GitHubScannerOverflowTests: XCTestCase {
    override func tearDown() {
        OverflowURLProtocol.reset()
        super.tearDown()
    }

    func testFullRecentPageRecoversOlderQueuedRunAndDeduplicatesRunStates() async throws {
        let recent = try runsJSON(ids: Array(1...50), status: "completed", total: 51)
        let queued = try runsJSON(ids: [99], status: "queued", total: 1)
        let running = try runsJSON(ids: [99], status: "in_progress", total: 1)
        let jobs = try jobsJSON(run: 99)
        OverflowURLProtocol.install { request in
            if request.url?.path.hasSuffix("/jobs") == true { return .ok(jobs) }
            switch Self.statusFilter(request) {
            case "queued":
                return .ok(queued)
            case "in_progress":
                return .ok(running)
            default:
                return .ok(recent)
            }
        }

        let result = await scan(runsPerRepository: 50)

        XCTAssertEqual(result.jobs.map(\.runId), [99])
        XCTAssertEqual(result.jobs.first?.labels, ["tartelet", "image"])
        XCTAssertFalse(result.truncated)
        XCTAssertTrue(result.warnings.isEmpty)
        let requests = OverflowURLProtocol.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/runs/99/jobs") == true }.count, 1)
        XCTAssertEqual(Set(requests.compactMap(Self.statusFilter)), ["queued", "in_progress"])
    }

    func testShortRecentPageDoesNotIssueOverflowQueries() async throws {
        let recent = try runsJSON(ids: [1], status: "queued", total: 1)
        let jobs = try jobsJSON(run: 1)
        OverflowURLProtocol.install { request in
            .ok(request.url?.path.hasSuffix("/jobs") == true ? jobs : recent)
        }

        let result = await scan()

        XCTAssertEqual(result.jobs.count, 1)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(OverflowURLProtocol.requests.count, 2)
        XCTAssertTrue(OverflowURLProtocol.requests.compactMap(Self.statusFilter).isEmpty)
    }

    func testFilteredRunCapIsReported() async throws {
        let recent = try runsJSON(ids: [1, 2], status: "completed", total: 10)
        let queued = try runsJSON(ids: [3, 4], status: "queued", total: 3)
        let running = try runsJSON(ids: [], status: "in_progress", total: 0)
        let jobs = try [3, 4].reduce(into: [String: Data]()) { result, id in
            result["/repos/owner/repository/actions/runs/\(id)/jobs"] = try jobsJSON(run: id)
        }
        OverflowURLProtocol.install { request in
            if let data = jobs[request.url?.path ?? ""] { return .ok(data) }
            switch Self.statusFilter(request) {
            case "queued":
                return .ok(queued)
            case "in_progress":
                return .ok(running)
            default:
                return .ok(recent)
            }
        }

        let result = await scan()

        XCTAssertTrue(result.truncated)
        XCTAssertEqual(Set(result.jobs.map(\.runId)), [3, 4])
        XCTAssertEqual(result.warnings, ["Only the first 2 queued runs for owner/repository were scanned."])
    }

    func testJobCapIsReportedButExactlyFullPagesAreComplete() async throws {
        let recent = try runsJSON(ids: [1, 2], status: "completed", total: 10)
        let queued = try runsJSON(ids: [3, 4], status: "queued", total: 2)
        let running = try runsJSON(ids: [], status: "in_progress", total: 0)
        let capped = try jobsJSON(run: 3, count: 100, total: 101)
        let complete = try jobsJSON(run: 4, count: 100, total: 100)
        OverflowURLProtocol.install { request in
            switch request.url?.path {
            case "/repos/owner/repository/actions/runs/3/jobs":
                return .ok(capped)
            case "/repos/owner/repository/actions/runs/4/jobs":
                return .ok(complete)
            default:
                switch Self.statusFilter(request) {
                case "queued":
                    return .ok(queued)
                case "in_progress":
                    return .ok(running)
                default:
                    return .ok(recent)
                }
            }
        }

        let result = await scan()

        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.jobs.count, 200)
        XCTAssertEqual(result.warnings, ["Only the first 100 jobs for run 3 in owner/repository were scanned."])
    }

    func testSkippedOverflowQueriesPropagateTruncationToPublicSnapshot() async throws {
        let recent = try runsJSON(ids: [1, 2], status: "completed", total: 10)
        OverflowURLProtocol.install { _ in
            OverflowResponse(status: 200, data: recent, headers: ["x-ratelimit-remaining": "199"])
        }

        let snapshot = try await makeScanner().queuedJobs(refresh: true)

        XCTAssertTrue(snapshot.truncated)
        XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertTrue(snapshot.warnings.contains { $0.contains("Skipped queued run recovery query") })
        XCTAssertTrue(snapshot.warnings.contains { $0.contains("Skipped in_progress run recovery query") })
        XCTAssertEqual(OverflowURLProtocol.requests.count, 1)
    }

    func testPartialJobScanningBudgetIsReported() async throws {
        let recent = try runsJSON(ids: [1], status: "queued", total: 1)
        OverflowURLProtocol.install { _ in
            OverflowResponse(status: 200, data: recent, headers: ["x-ratelimit-remaining": "199"])
        }

        let result = await scan()

        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.warnings.contains { $0.contains("Stopped before scanning all discovered unfinished runs") })
        XCTAssertEqual(OverflowURLProtocol.requests.count, 1)
    }

    func testExpiredDeadlineDoesNotStartRepositoryRequests() async {
        let result = await makeScanner().scanRepository(
            "owner/repository", token: "installation-token", cache: [:],
            runsPerRepository: 2, rateLimitFloor: 200, deadline: .distantPast
        )

        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.warnings, ["Skipped owner/repository: scan time budget exhausted."])
        XCTAssertTrue(OverflowURLProtocol.requests.isEmpty)
    }

    func testRunnerObservationsDoNotBecomeQueuedSchedulingDemand() async throws {
        let recent = try runsJSON(ids: [7], status: "in_progress", total: 1)
        let jobs = try JSONSerialization.data(withJSONObject: [
            "total_count": 5,
            "jobs": [
                ["id": 1, "run_id": 7, "name": "Queued", "status": "queued", "labels": ["image"], "head_branch": "feature/metadata", "head_sha": "abc123", "run_attempt": 2],
                ["id": 2, "run_id": 7, "name": "Running", "status": "in_progress", "labels": ["image"], "runner_name": "vm-two"],
                ["id": 3, "run_id": 7, "name": "Finished", "status": "completed", "labels": ["image"], "runner_name": "vm-three", "conclusion": "success"],
                ["id": 4, "run_id": 7, "name": "No runner", "status": "in_progress", "labels": ["image"]],
                ["id": 5, "run_id": 7, "name": "Empty runner", "status": "completed", "labels": ["image"], "runner_name": ""]
            ] as [[String: Any]]
        ])
        OverflowURLProtocol.install { request in
            .ok(request.url?.path.hasSuffix("/jobs") == true ? jobs : recent)
        }

        let snapshot = try await makeScanner().queuedJobs(refresh: true)

        XCTAssertEqual(snapshot.jobs.map(\.id), [1])
        XCTAssertEqual(snapshot.jobs.first?.details?.headBranch, "feature/metadata")
        XCTAssertEqual(snapshot.jobs.first?.details?.headSha, "abc123")
        XCTAssertEqual(snapshot.jobs.first?.details?.runAttempt, 2)
        XCTAssertNotNil(snapshot.jobs.first?.details?.observedAt)
        XCTAssertEqual(snapshot.runnerJobs.map(\.id), [2, 3])
        XCTAssertEqual(snapshot.runnerJobs.map(\.runnerName), ["vm-two", "vm-three"])
        XCTAssertEqual(snapshot.runnerJobs.last?.conclusion, "success")
        XCTAssertNotNil(snapshot.runnerJobs.first?.observedAt)
        XCTAssertEqual(OverflowURLProtocol.requests.count, 2)
    }

    private func scan(runsPerRepository: Int = 2) async -> GitHubActionsScanner.RepositoryScanResult {
        await makeScanner().scanRepository(
            "owner/repository", token: "installation-token", cache: [:],
            runsPerRepository: runsPerRepository, rateLimitFloor: 200,
            deadline: Date().addingTimeInterval(10)
        )
    }

    private func makeScanner() -> GitHubActionsScanner {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OverflowURLProtocol.self]
        return GitHubActionsScanner(
            client: OverflowGitHubClient(),
            credentialsStore: OverflowCredentials(),
            runnerScope: .repo,
            configuration: .init(runsPerRepository: 2),
            logger: OverflowLogger(),
            session: URLSession(configuration: configuration)
        )
    }

    private func runsJSON(ids: [Int], status: String, total: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "total_count": total,
            "workflow_runs": ids.map { ["id": $0, "status": status] as [String: Any] }
        ])
    }

    private func jobsJSON(run: Int, count: Int = 1, total: Int? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "total_count": total ?? count,
            "jobs": (0..<count).map { index in
                [
                    "id": run * 1_000 + index, "run_id": run,
                    "name": "Build", "status": "queued", "labels": ["tartelet", "image"]
                ] as [String: Any]
            }
        ])
    }

    private static func statusFilter(_ request: URLRequest) -> String? {
        guard let url = request.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "status" }?.value
    }
}

private final class OverflowGitHubClient: GitHubClient {
    func getAppAccessToken(runnerScope _: GitHubRunnerScope) async throws -> GitHubAppAccessToken {
        GitHubAppAccessToken("installation-token")
    }

    func getRunnerRegistrationToken(with _: GitHubAppAccessToken, runnerScope _: GitHubRunnerScope) async throws -> GitHubRunnerRegistrationToken {
        throw GitHubJobLookupError.unsupported
    }

    func getRunnerDownloadURL(with _: GitHubAppAccessToken, runnerScope _: GitHubRunnerScope) async throws -> URL {
        throw GitHubJobLookupError.unsupported
    }
}

private final class OverflowCredentials: GitHubCredentialsStore {
    let organizationName: String? = nil
    let repositoryName: String? = "repository"
    let ownerName: String? = "owner"
    let appId: String? = nil
    let privateKey: Data? = nil
}

private final class OverflowLogger: Logger {
    func info(_: String, parameters _: [String: String]?) {}
    func error(_: String, parameters _: [String: String]?) {}
}

private struct OverflowResponse {
    let status: Int
    let data: Data
    let headers: [String: String]

    static func ok(_ data: Data) -> Self {
        Self(status: 200, data: data, headers: [:])
    }
}

private final class OverflowURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> OverflowResponse)?
    private static var capturedRequests: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { capturedRequests } }

    static func install(_ response: @escaping (URLRequest) -> OverflowResponse) {
        lock.withLock {
            handler = response
            capturedRequests = []
        }
    }

    static func reset() {
        lock.withLock {
            handler = nil
            capturedRequests = []
        }
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { () -> ((URLRequest) -> OverflowResponse)? in
            Self.capturedRequests.append(request)
            return Self.handler
        }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let outcome = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: outcome.status, httpVersion: nil, headerFields: outcome.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: outcome.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
