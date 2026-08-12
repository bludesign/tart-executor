import Foundation

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
    let workflowRuns: [GitHubWorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

struct GitHubWorkflowRun: Decodable {
    let id: Int
    /// `queued`, `in_progress`, `completed`, `waiting`, `requested`, `pending`.
    let status: String?
}

struct GitHubJobsPage: Decodable {
    let jobs: [GitHubJob]
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
