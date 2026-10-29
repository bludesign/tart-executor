import Foundation
import GitHubDomain

// The networking service decodes with a plain `JSONDecoder` (no key or date strategy), so these
// spell out their snake_case keys and keep timestamps as strings for `GitHubDateParser`.

struct GitHubInstallationRepository: Decodable {
    let fullName: String
    let archived: Bool?
    let pushedAt: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case archived
        case pushedAt = "pushed_at"
    }
}

struct GitHubInstallationRepositoriesPage: Decodable {
    let totalCount: Int
    let repositories: [GitHubInstallationRepository]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case repositories
    }
}

struct GitHubWorkflowRunsPage: Decodable {
    let totalCount: Int?
    let workflowRuns: [GitHubWorkflowRun]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case workflowRuns = "workflow_runs"
    }
}

struct GitHubWorkflowRun: Decodable {
    let id: Int
    /// `queued`, `in_progress`, `completed`, `waiting`, `requested`, `pending`.
    let status: String?
}

struct GitHubWorkflowRunDetails: Decodable, Sendable {
    struct Actor: Decodable, Sendable {
        let login: String
    }

    let id: Int
    let htmlUrl: String?
    let displayTitle: String?
    let runNumber: Int?
    let event: String?
    let actor: Actor?

    enum CodingKeys: String, CodingKey {
        case id, event, actor
        case htmlUrl = "html_url"
        case displayTitle = "display_title"
        case runNumber = "run_number"
    }
}

struct GitHubJobsPage: Decodable {
    let totalCount: Int?
    let jobs: [GitHubJob]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case jobs
    }
}

struct GitHubJob: Decodable {
    let id: Int
    let runId: Int
    let name: String
    let workflowName: String?
    let status: String
    let labels: [String]
    let htmlUrl: String?
    let createdAt: String?
    let startedAt: String?
    let runnerName: String?
    let headBranch: String?
    let headSha: String?
    let runAttempt: Int?
    let conclusion: String?
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case name
        case workflowName = "workflow_name"
        case status
        case labels
        case htmlUrl = "html_url"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case runnerName = "runner_name"
        case headBranch = "head_branch"
        case headSha = "head_sha"
        case runAttempt = "run_attempt"
        case conclusion
        case completedAt = "completed_at"
    }

    func asStatus(repository: String, run: GitHubWorkflowRunDetails? = nil) -> GitHubJobStatus {
        GitHubJobStatus(
            id: id, repository: repository, status: status, labels: Set(labels), runnerName: runnerName,
            runId: runId, name: name, workflowName: workflowName, htmlUrl: htmlUrl,
            headBranch: headBranch, headSha: headSha, runAttempt: runAttempt, conclusion: conclusion,
            createdAt: GitHubDateParser.date(from: createdAt), startedAt: GitHubDateParser.date(from: startedAt),
            completedAt: GitHubDateParser.date(from: completedAt), runUrl: run?.htmlUrl,
            runTitle: run?.displayTitle, runNumber: run?.runNumber, event: run?.event,
            actor: run?.actor?.login, observedAt: Date()
        )
    }
}

/// GitHub returns `2026-08-12T10:00:00Z`; some fields carry fractional seconds.
enum GitHubDateParser {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return plain.date(from: string) ?? withFractionalSeconds.date(from: string)
    }
}
