import Foundation
@testable import GitHubData
import GitHubDomain
import LoggingDomain
import XCTest

final class GitHubJobLookupTests: XCTestCase {
    override func setUp() {
        super.setUp()
        JobURLProtocol.reset()
    }

    func testQueuedJobUsesExactEndpointAndPreservesLabels() async throws {
        JobURLProtocol.enqueue(status: 200, body: jobJSON(status: "queued", runnerName: nil))
        let scanner = makeScanner()

        let job = try await scanner.job(id: 42, repository: "owner/repository")

        XCTAssertEqual(job.id, 42)
        XCTAssertEqual(job.repository, "owner/repository")
        XCTAssertEqual(job.status, "queued")
        XCTAssertEqual(job.labels, ["tartelet", "image", "cpu:7", "memory:24576"])
        XCTAssertNil(job.runnerName)
        let request = try XCTUnwrap(JobURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/repos/owner/repository/actions/jobs/42")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer installation-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testEachLookupReadsCurrentStatusAndRunner() async throws {
        JobURLProtocol.enqueue(status: 200, body: jobJSON(status: "in_progress", runnerName: "runner-1"))
        JobURLProtocol.enqueue(status: 200, body: jobJSON(status: "completed", runnerName: "runner-1"))
        let scanner = makeScanner()

        let running = try await scanner.job(id: 42, repository: "owner/repository")
        let completed = try await scanner.job(id: 42, repository: "owner/repository")

        XCTAssertEqual(running.status, "in_progress")
        XCTAssertEqual(running.runnerName, "runner-1")
        XCTAssertEqual(completed.status, "completed")
        XCTAssertEqual(JobURLProtocol.requests.count, 2)
        XCTAssertTrue(JobURLProtocol.requests.allSatisfy { request in
            request.value(forHTTPHeaderField: "If-None-Match") == nil
        })
    }

    func testDeniedAndMissingJobsThrowInsteadOfReturningPreviousStatus() async throws {
        JobURLProtocol.enqueue(status: 200, body: jobJSON(status: "queued", runnerName: nil))
        JobURLProtocol.enqueue(status: 403, body: #"{"message":"Resource not accessible by integration"}"#)
        JobURLProtocol.enqueue(status: 404, body: #"{"message":"Not Found"}"#)
        let scanner = makeScanner()
        _ = try await scanner.job(id: 42, repository: "owner/repository")

        for _ in 0..<2 {
            do {
                _ = try await scanner.job(id: 42, repository: "owner/repository")
                XCTFail("An unavailable job must remain unknown")
            } catch is GitHubJobLookupError {
                // Expected: no cached queued/completed state is supplied.
            }
        }
        XCTAssertEqual(JobURLProtocol.requests.count, 3)
    }

    func testMismatchedJobIdIsRejected() async throws {
        JobURLProtocol.enqueue(status: 200, body: jobJSON(id: 43, status: "completed", runnerName: nil))
        do {
            _ = try await makeScanner().job(id: 42, repository: "owner/repository")
            XCTFail("A response for another job must be rejected")
        } catch GitHubJobLookupError.mismatchedJobId {
            // Expected.
        }
    }

    func testInvalidRepositoryAndJobIdNeverReachGitHub() async throws {
        let client = LookupGitHubClient()
        let scanner = makeScanner(client: client)
        let invalid = ["owner", "owner/repo/extra", "/owner/repo", "owner/", "owner/..", "./repo", "owner/%2e%2e"]
        for repository in invalid {
            do {
                _ = try await scanner.job(id: 42, repository: repository)
                XCTFail("Invalid repository accepted: \(repository)")
            } catch GitHubJobLookupError.invalidRepository {
                // Expected.
            }
        }
        do {
            _ = try await scanner.job(id: 0, repository: "owner/repository")
            XCTFail("Invalid job id accepted")
        } catch GitHubJobLookupError.invalidJobId {
            // Expected.
        }
        XCTAssertEqual(client.tokenCalls, 0)
        XCTAssertTrue(JobURLProtocol.requests.isEmpty)
    }

    func testRejectedTokenIsRenewedForNextLookup() async throws {
        JobURLProtocol.enqueue(status: 401, body: #"{"message":"Bad credentials"}"#)
        JobURLProtocol.enqueue(status: 200, body: jobJSON(status: "queued", runnerName: nil))
        let client = LookupGitHubClient()
        let scanner = makeScanner(client: client)
        do {
            _ = try await scanner.job(id: 42, repository: "owner/repository")
            XCTFail("Rejected credentials must leave job status unknown")
        } catch is GitHubJobLookupError {
            // Expected.
        }

        _ = try await scanner.job(id: 42, repository: "owner/repository")

        XCTAssertEqual(client.tokenCalls, 2)
    }

    private func makeScanner(client: LookupGitHubClient = LookupGitHubClient()) -> GitHubActionsScanner {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JobURLProtocol.self]
        return GitHubActionsScanner(
            client: client,
            credentialsStore: LookupCredentials(),
            runnerScope: .organization,
            configuration: .default,
            logger: LookupLogger(),
            session: URLSession(configuration: configuration)
        )
    }

    private func jobJSON(id: Int = 42, status: String, runnerName: String?) -> String {
        let runner = runnerName.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":\(id),"run_id":7,"name":"Build","status":"\(status)",
         "labels":["tartelet","image","cpu:7","memory:24576"],"runner_name":\(runner)}
        """
    }
}

private final class LookupGitHubClient: GitHubClient {
    var tokenCalls = 0

    func getAppAccessToken(runnerScope _: GitHubRunnerScope) async throws -> GitHubAppAccessToken {
        tokenCalls += 1
        return GitHubAppAccessToken("installation-token")
    }

    func getRunnerRegistrationToken(
        with _: GitHubAppAccessToken,
        runnerScope _: GitHubRunnerScope
    ) async throws -> GitHubRunnerRegistrationToken {
        throw GitHubJobLookupError.unsupported
    }

    func getRunnerDownloadURL(with _: GitHubAppAccessToken, runnerScope _: GitHubRunnerScope) async throws -> URL {
        throw GitHubJobLookupError.unsupported
    }
}

private final class LookupCredentials: GitHubCredentialsStore {
    let organizationName: String? = "owner"
    let repositoryName: String? = nil
    let ownerName: String? = nil
    let appId: String? = nil
    let privateKey: Data? = nil
}

private final class LookupLogger: Logger {
    func info(_: String, parameters _: [String: String]?) {}
    func error(_: String, parameters _: [String: String]?) {}
}

private final class JobURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses = [(status: Int, body: String)]()
    private static var capturedRequests = [URLRequest]()

    static var requests: [URLRequest] {
        lock.withLock { capturedRequests }
    }

    static func reset() {
        lock.withLock {
            responses = []
            capturedRequests = []
        }
    }

    static func enqueue(status: Int, body: String) {
        lock.withLock { responses.append((status, body)) }
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.lock.withLock { () -> (status: Int, body: String)? in
            Self.capturedRequests.append(request)
            return Self.responses.isEmpty ? nil : Self.responses.removeFirst()
        }
        guard let response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "ETag": "lookup-response"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
