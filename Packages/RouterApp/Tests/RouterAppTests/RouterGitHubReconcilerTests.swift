import EnvironmentSettings
import Foundation
import LoggingDomain
@testable import RouterApp
import TartCommon
import XCTest

final class RouterGitHubReconcilerTests: XCTestCase {
    override func tearDown() {
        ReconciliationURLProtocol.reset()
        super.tearDown()
    }

    func testUnauthorizedSourceFallsBackAndUsesRouterLabels() async throws {
        let matchingJob = makeJob(id: 1, labels: ["tartelet", "image"], matchesRunnerLabels: false)
        let unrelatedJob = makeJob(id: 2, labels: ["other", "image"], matchesRunnerLabels: true)
        let snapshot = makeSnapshot(jobs: [matchingJob, unrelatedJob], warnings: ["Partial scan"], truncated: true)
        let data = try JSONEncoder.api.encode(snapshot)
        ReconciliationURLProtocol.install { request in
            request.url?.host == "primary.test" ? (401, Data()) : (200, data)
        }
        let reconciler = makeReconciler(apiToken: "executor-token")

        let result = try await reconciler.queuedJobs()

        XCTAssertEqual(result.jobs.map(\.id), [1])
        XCTAssertFalse(try XCTUnwrap(result.jobs.first).matchesRunnerLabels)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.warnings, ["Partial scan"])
        let requests = ReconciliationURLProtocol.requests
        XCTAssertEqual(requests.compactMap { $0.url?.host }, ["primary.test", "secondary.test"])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer executor-token")
            XCTAssertGreaterThan(request.timeoutInterval, 29)
            XCTAssertLessThanOrEqual(request.timeoutInterval, 30)
            let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first { $0.name == "matching" }?.value, "all")
            XCTAssertEqual(items?.first { $0.name == "refresh" }?.value, "true")
        }
    }

    func testStaleRefreshFallsBackToFreshSource() async throws {
        let stale = try JSONEncoder.api.encode(makeSnapshot(scannedAt: Date().addingTimeInterval(-10)))
        let fresh = try JSONEncoder.api.encode(makeSnapshot())
        ReconciliationURLProtocol.install { request in
            (200, request.url?.host == "primary.test" ? stale : fresh)
        }

        let result = try await makeReconciler().queuedJobs()

        XCTAssertTrue(result.jobs.isEmpty)
        XCTAssertEqual(ReconciliationURLProtocol.requests.count, 2)
    }

    func testAllStaleSourcesFailInsteadOfProvisioningFromOldData() async throws {
        let stale = try JSONEncoder.api.encode(makeSnapshot(scannedAt: Date().addingTimeInterval(-120)))
        ReconciliationURLProtocol.install { _ in (200, stale) }

        do {
            _ = try await makeReconciler().queuedJobs()
            XCTFail("Stale GitHub snapshots must not be used for provisioning")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stale"))
        }
    }

    func testExactLookupRejectsMismatchedJobAndPreservesRepository() async throws {
        let wrong = Data(#"{"id":99,"repository":"owner/repo","status":"completed","labels":["tartelet","image"]}"#.utf8)
        let correct = Data(#"{"id":42,"repository":"owner/repo","status":"completed","labels":["tartelet","image"],"runnerName":"runner-42"}"#.utf8)
        ReconciliationURLProtocol.install { request in
            (200, request.url?.host == "primary.test" ? wrong : correct)
        }

        let job = try await makeReconciler().job(id: 42, repository: "owner/repo")

        XCTAssertEqual(job.id, 42)
        XCTAssertEqual(job.status, "completed")
        XCTAssertEqual(job.runnerName, "runner-42")
        for request in ReconciliationURLProtocol.requests {
            XCTAssertEqual(request.url?.path, "/api/v1/github/jobs/42")
            XCTAssertLessThanOrEqual(request.timeoutInterval, 5)
            let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first { $0.name == "repository" }?.value, "owner/repo")
        }
    }

    func testReconciliationConfigurationDefaultsAndLegacyRouterConfiguration() throws {
        let decoder = JSONDecoder()
        let defaults = try decoder.decode(RouterReconciliationConfiguration.self, from: Data("{}".utf8))
        XCTAssertTrue(defaults.enabled)
        XCTAssertEqual(defaults.intervalSeconds, 60)
        XCTAssertNil(defaults.executorApiToken)
        let custom = try decoder.decode(
            RouterReconciliationConfiguration.self,
            from: Data(#"{"enabled":false,"intervalSeconds":0,"executorApiToken":"shared-token"}"#.utf8)
        )
        XCTAssertFalse(custom.enabled)
        XCTAssertEqual(custom.intervalSeconds, 1)
        XCTAssertEqual(custom.executorApiToken, "shared-token")
        let legacy = try decoder.decode(
            RouterEnvironment.self,
            from: Data(#"{"hostname":"router","labels":"tartelet","port":3251,"hosts":[]}"#.utf8)
        )
        XCTAssertNil(legacy.reconciliation)
    }

    private func makeReconciler(apiToken: String? = nil) -> RouterGitHubReconciler {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReconciliationURLProtocol.self]
        return RouterGitHubReconciler(
            hosts: ["primary", "secondary"].enumerated().map { index, name in
                TartHost(
                    hostname: name,
                    url: URL(string: "http://\(name).test:3250")!,
                    priority: index,
                    cpuLimit: nil,
                    memoryLimit: nil
                )
            },
            labels: ["tartelet"],
            logger: ReconciliationTestLogger(),
            apiToken: apiToken,
            session: URLSession(configuration: configuration)
        )
    }

    private func makeSnapshot(
        jobs: [GitHubQueuedJobDTO] = [],
        scannedAt: Date = Date(),
        warnings: [String] = [],
        truncated: Bool = false
    ) -> GitHubQueuedJobsResponse {
        GitHubQueuedJobsResponse(
            hostname: "executor",
            jobs: jobs,
            scannedAt: scannedAt,
            repositoriesScanned: 1,
            truncated: truncated,
            warnings: warnings,
            rateLimitRemaining: 1_000,
            rateLimitResetAt: nil
        )
    }

    private func makeJob(id: Int, labels: [String], matchesRunnerLabels: Bool) -> GitHubQueuedJobDTO {
        GitHubQueuedJobDTO(
            id: id,
            runId: 1,
            name: "Build",
            workflowName: nil,
            repository: "owner/repo",
            htmlUrl: nil,
            labels: labels,
            createdAt: Date(),
            matchesRunnerLabels: matchesRunnerLabels,
            labelMismatchReason: nil,
            imageName: nil,
            cpu: nil,
            memory: nil
        )
    }
}

private final class ReconciliationTestLogger: Logger {
    func info(_: String, parameters _: [String: String]?) {}
    func error(_: String, parameters _: [String: String]?) {}
}

private final class ReconciliationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, Data))?
    private static var capturedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    static func install(_ response: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock()
        defer { lock.unlock() }
        handler = response
        capturedRequests = []
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        capturedRequests = []
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
