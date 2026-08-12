import Foundation

/// A GitHub Actions job that GitHub currently reports as `queued`, i.e. waiting for a runner to
/// pick it up.
public struct GitHubQueuedJob: Sendable, Identifiable, Hashable {
    public let id: Int
    public let runId: Int
    public let name: String
    public let workflowName: String?
    /// `owner/repo`.
    public let repositoryFullName: String
    public let htmlURL: String?
    /// The `runs-on` labels, exactly as GitHub reports them.
    public let labels: Set<String>
    public let createdAt: Date
    public let startedAt: Date?

    public init(
        id: Int,
        runId: Int,
        name: String,
        workflowName: String?,
        repositoryFullName: String,
        htmlURL: String?,
        labels: Set<String>,
        createdAt: Date,
        startedAt: Date?
    ) {
        self.id = id
        self.runId = runId
        self.name = name
        self.workflowName = workflowName
        self.repositoryFullName = repositoryFullName
        self.htmlURL = htmlURL
        self.labels = labels
        self.createdAt = createdAt
        self.startedAt = startedAt
    }
}

/// The result of one scan pass. A scan that hit a cap, a time budget, or the rate-limit floor
/// still returns whatever it found, with `truncated` set and the reason in `warnings` — an
/// incomplete scan must never be mistaken for an empty queue.
public struct GitHubQueuedJobsSnapshot: Sendable {
    public let jobs: [GitHubQueuedJob]
    public let scannedAt: Date
    public let repositoriesScanned: Int
    public let truncated: Bool
    public let warnings: [String]
    public let rateLimitRemaining: Int?
    public let rateLimitResetAt: Date?

    public init(
        jobs: [GitHubQueuedJob],
        scannedAt: Date,
        repositoriesScanned: Int,
        truncated: Bool,
        warnings: [String],
        rateLimitRemaining: Int?,
        rateLimitResetAt: Date?
    ) {
        self.jobs = jobs
        self.scannedAt = scannedAt
        self.repositoriesScanned = repositoriesScanned
        self.truncated = truncated
        self.warnings = warnings
        self.rateLimitRemaining = rateLimitRemaining
        self.rateLimitResetAt = rateLimitResetAt
    }
}
