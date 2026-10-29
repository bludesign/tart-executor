import Foundation
import TartCommon
import XCTest

final class GitHubJobContextTests: XCTestCase {
    func testWebhookPreservesMetadataAndFractionalTimestamps() throws {
        let body = Data("""
        {"action":"in_progress","repository":{"full_name":"owner/repo"},"workflow_job":{
          "id":9000000001,"run_id":8000000001,"run_attempt":2,"name":"Test (macOS)",
          "workflow_name":"CI","html_url":"https://github.com/owner/repo/actions/runs/8/job/9",
          "head_branch":"feature/example","head_sha":"abc123","status":"in_progress",
          "runner_name":"vm-two","started_at":"2026-10-29T08:00:00.123Z","labels":["runner","image"]}}
        """.utf8)
        let payload = try JSONDecoder.api.decode(WebhookResponse.self, from: body)
        let context = payload.jobContext
        XCTAssertEqual(context.workflowJobId, "9000000001")
        XCTAssertEqual(context.workflowRunId, "8000000001")
        XCTAssertEqual(context.repository, "owner/repo")
        XCTAssertEqual(context.name, "Test (macOS)")
        XCTAssertEqual(context.runAttempt, 2)
        XCTAssertEqual(context.runnerName, "vm-two")
        XCTAssertNotNil(context.startedAt)
        let roundTrip = try JSONDecoder.api.decode(GitHubJobContext.self, from: JSONEncoder.api.encode(context))
        XCTAssertEqual(roundTrip.workflowJobId, context.workflowJobId)
    }

    func testSparseEnrichmentCannotRegressCompletionOrLoseIdentity() {
        let original = GitHubJobContext(
            workflowJobId: "1", repository: "owner/repo", name: "Test", status: "completed",
            conclusion: "success", runnerName: "vm-one", observedAt: Date(timeIntervalSince1970: 20)
        )
        let late = GitHubJobContext(
            workflowJobId: "1", runTitle: "Useful run title", status: "in_progress",
            observedAt: Date(timeIntervalSince1970: 30)
        )
        let merged = original.merging(late)
        XCTAssertEqual(merged.status, "completed")
        XCTAssertEqual(merged.conclusion, "success")
        XCTAssertEqual(merged.runnerName, "vm-one")
        XCTAssertEqual(merged.name, "Test")
        XCTAssertEqual(merged.runTitle, "Useful run title")
        XCTAssertEqual(original.merging(.init(workflowJobId: "2")), original)
    }

    func testOlderPayloadsAndNormalizedDispatchRemainDecodable() throws {
        let payload = try JSONDecoder.api.decode(WebhookResponse.self, from: Data("""
        {"action":"queued","workflow_job":{"id":42,"labels":["runner","image"]}}
        """.utf8))
        XCTAssertEqual(payload.jobContext.workflowJobId, "42")
        XCTAssertNil(payload.jobContext.repository)
        var job = WebhookResponse.WorkflowJobResponse(id: 42, labels: ["runner", "image"])
        job.github = .init(workflowJobId: "42", name: "Recovered", createdAt: Date())
        let normalized = WebhookResponse(action: .queued, workflow_job: job)
        let decoded = try JSONDecoder.api.decode(WebhookResponse.self, from: JSONEncoder.api.encode(normalized))
        XCTAssertEqual(decoded.jobContext.name, "Recovered")
    }
}
