import Foundation

/// Display metadata and positive runner observations. This never authorizes lifecycle changes.
public struct GitHubJobContext: Codable, Sendable, Hashable {
    public let workflowJobId: String
    public var workflowRunId: String?
    public var repository: String?
    public var name: String?
    public var workflowName: String?
    public var htmlUrl: String?
    public var runUrl: String?
    public var runTitle: String?
    public var runNumber: Int?
    public var runAttempt: Int?
    public var event: String?
    public var actor: String?
    public var headBranch: String?
    public var headSha: String?
    public var status: String?
    public var conclusion: String?
    public var runnerName: String?
    public var createdAt: Date?
    public var startedAt: Date?
    public var completedAt: Date?
    public var observedAt: Date?
    public var source: String?
    public var warnings: [String]?

    public init(
        workflowJobId: String, workflowRunId: String? = nil, repository: String? = nil,
        name: String? = nil, workflowName: String? = nil, htmlUrl: String? = nil,
        runUrl: String? = nil, runTitle: String? = nil, runNumber: Int? = nil, runAttempt: Int? = nil,
        event: String? = nil, actor: String? = nil, headBranch: String? = nil, headSha: String? = nil,
        status: String? = nil, conclusion: String? = nil, runnerName: String? = nil,
        createdAt: Date? = nil, startedAt: Date? = nil, completedAt: Date? = nil,
        observedAt: Date? = nil, source: String? = nil, warnings: [String]? = nil
    ) {
        self.workflowJobId = workflowJobId
        self.workflowRunId = workflowRunId
        self.repository = repository
        self.name = name
        self.workflowName = workflowName
        self.htmlUrl = htmlUrl
        self.runUrl = runUrl
        self.runTitle = runTitle
        self.runNumber = runNumber
        self.runAttempt = runAttempt
        self.event = event
        self.actor = actor
        self.headBranch = headBranch
        self.headSha = headSha
        self.status = status
        self.conclusion = conclusion
        self.runnerName = runnerName
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.observedAt = observedAt
        self.source = source
        self.warnings = warnings
    }

    /// Merge sparse enrichment without losing webhook fields or regressing a completed job.
    public func merging(_ update: Self) -> Self {
        guard workflowJobId == update.workflowJobId else { return self }
        var result = self
        result.workflowRunId = update.workflowRunId ?? workflowRunId
        result.repository = update.repository ?? repository
        result.name = update.name ?? name
        result.workflowName = update.workflowName ?? workflowName
        result.htmlUrl = update.htmlUrl ?? htmlUrl
        result.runUrl = update.runUrl ?? runUrl
        result.runTitle = update.runTitle ?? runTitle
        result.runNumber = update.runNumber ?? runNumber
        result.runAttempt = update.runAttempt ?? runAttempt
        result.event = update.event ?? event
        result.actor = update.actor ?? actor
        result.headBranch = update.headBranch ?? headBranch
        result.headSha = update.headSha ?? headSha
        result.createdAt = update.createdAt ?? createdAt
        result.startedAt = update.startedAt ?? startedAt
        let isNewer = (update.observedAt ?? .distantPast) >= (observedAt ?? .distantPast)
        let regressesProgress = status == "in_progress" && update.status == "queued"
        let confirmsCompletion = update.status == "completed" && status != "completed"
        if status != "completed" || update.status == "completed", !regressesProgress, isNewer || confirmsCompletion {
            result.status = update.status ?? status
            result.conclusion = update.conclusion ?? conclusion
            result.runnerName = update.runnerName ?? runnerName
            result.completedAt = update.completedAt ?? completedAt
            result.observedAt = update.observedAt ?? observedAt
            result.source = update.source ?? source
            result.warnings = update.warnings ?? warnings
        }
        return result
    }
}

public struct GitHubJobObservationsRequest: Codable, Sendable {
    public let jobs: [GitHubJobContext]

    public init(jobs: [GitHubJobContext]) { self.jobs = jobs }
}
