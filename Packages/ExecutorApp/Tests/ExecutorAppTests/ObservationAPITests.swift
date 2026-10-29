@testable import ExecutorApp
import FlyingFox
import Foundation
import GitHubDomain
import LoggingDomain
import TartCommon
import VirtualMachineDomain
import XCTest

final class ObservationAPITests: XCTestCase {
    func testAuthenticationPrecedesObservationProcessing() async throws {
        let server = makeServer()
        let response = await server.jobObservationsResponse(for: request(body: Data("bad JSON".utf8)))
        XCTAssertEqual(response.statusCode, .unauthorized)
    }

    func testAuthorizedObservationNeverCreatesJobOrVM() async throws {
        let server = makeServer()
        let body = try JSONEncoder.api.encode(GitHubJobObservationsRequest(jobs: [
            .init(workflowJobId: "9000000001", status: "in_progress", runnerName: "unknown-vm")
        ]))
        let response = await server.jobObservationsResponse(for: request(body: body, token: "test-token"))
        XCTAssertEqual(response.statusCode, .ok)
        let jobs = await server.jobHandler.jobsSnapshot()
        XCTAssertTrue(jobs.isEmpty)
        let status = await server.jobHandler.jobStatus
        XCTAssertEqual(status.virtualMachines, 0)
    }

    func testInvalidObservationIDsAndOversizedBatchesAreRejected() async throws {
        let server = makeServer()
        for jobs in [
            [GitHubJobContext(workflowJobId: "-1")],
            [GitHubJobContext(workflowJobId: "0001")],
            Array(repeating: GitHubJobContext(workflowJobId: "1"), count: 1_001)
        ] {
            let body = try JSONEncoder.api.encode(GitHubJobObservationsRequest(jobs: jobs))
            let response = await server.jobObservationsResponse(for: request(body: body, token: "test-token"))
            XCTAssertEqual(response.statusCode, .badRequest)
        }
    }

    private func request(body: Data, token: String? = nil) -> HTTPRequest {
        HTTPRequest(
            method: .POST, version: .http11, path: "/api/v1/github/job-observations", query: [],
            headers: token.map { [.authorization: "Bearer \($0)"] } ?? [:], body: body
        )
    }

    private func makeServer() -> ExecutorServer {
        ExecutorServer(logger: APILogger(), virtualMachineProvider: APIProvider(), settings: APISettings())
    }
}

private struct APISettings: ExecutorServerSettings {
    let numberOfMachines = 2
    let runnerLabels = "runner"
    let webhookPort = 0
    let routerUrl: String? = nil
    let localUrl: String? = nil
    let isHeadless = true
    let isInsecure = false
    let insecureDomains = [String]()
    let netBridgedAdapter: String? = nil
    let defaultCpu: Int? = 2
    let defaultMemory: Int? = 4_096
    let hostname = "test-host"
    let cpuLimit = 8
    let totalMemory = 16_384
    let loggingEndpoint: String? = nil
    let apiToken: String? = "test-token"
    let gitHubScan = GitHubScanConfiguration()
}

private final class APILogger: Logger {
    func info(_: String, parameters _: [String: String]?) {}
    func error(_: String, parameters _: [String: String]?) {}
}

private final class APIProvider: VirtualMachineProvider {
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
