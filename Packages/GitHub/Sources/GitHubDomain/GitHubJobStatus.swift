import Foundation

/// A fresh lookup of one job, used when deciding whether a runner is still needed.
public struct GitHubJobStatus: Sendable, Hashable {
    public let id: Int
    public let repository: String
    public let status: String
    public let labels: Set<String>
    public let runnerName: String?
    public let runId: Int?
    public let name: String?
    public let workflowName: String?
    public let htmlUrl: String?
    public let headBranch: String?
    public let headSha: String?
    public let runAttempt: Int?
    public let conclusion: String?
    public let createdAt: Date?
    public let startedAt: Date?
    public let completedAt: Date?
    public let runUrl: String?
    public let runTitle: String?
    public let runNumber: Int?
    public let event: String?
    public let actor: String?
    public let observedAt: Date?

    public init(
        id: Int, repository: String, status: String, labels: Set<String>, runnerName: String?,
        runId: Int? = nil, name: String? = nil, workflowName: String? = nil,
        htmlUrl: String? = nil, headBranch: String? = nil, headSha: String? = nil,
        runAttempt: Int? = nil, conclusion: String? = nil, createdAt: Date? = nil,
        startedAt: Date? = nil, completedAt: Date? = nil, runUrl: String? = nil,
        runTitle: String? = nil, runNumber: Int? = nil, event: String? = nil,
        actor: String? = nil, observedAt: Date? = nil
    ) {
        self.id = id
        self.repository = repository
        self.status = status
        self.labels = labels
        self.runnerName = runnerName
        self.runId = runId
        self.name = name
        self.workflowName = workflowName
        self.htmlUrl = htmlUrl
        self.headBranch = headBranch
        self.headSha = headSha
        self.runAttempt = runAttempt
        self.conclusion = conclusion
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.runUrl = runUrl
        self.runTitle = runTitle
        self.runNumber = runNumber
        self.event = event
        self.actor = actor
        self.observedAt = observedAt
    }

    /// Accepts exactly an owner and repository, never a path or URL supplied by the caller.
    public static func isValidRepository(_ repository: String) -> Bool {
        let components = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        return components.count == 2 && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
                && component.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}

public enum GitHubJobLookupError: LocalizedError {
    case unsupported
    case invalidRepository
    case invalidJobId
    case mismatchedJobId
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Exact GitHub job lookup is not supported by this provider"
        case .invalidRepository:
            return "repository must be an owner/repository name"
        case .invalidJobId:
            return "Job id must be positive"
        case .mismatchedJobId:
            return "GitHub returned a different job id"
        case let .unavailable(reason):
            return reason
        }
    }
}
