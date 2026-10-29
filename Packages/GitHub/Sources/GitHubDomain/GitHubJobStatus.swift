import Foundation

/// A fresh lookup of one job, used when deciding whether a runner is still needed.
public struct GitHubJobStatus: Sendable {
    public let id: Int
    public let repository: String
    public let status: String
    public let labels: Set<String>
    public let runnerName: String?

    public init(id: Int, repository: String, status: String, labels: Set<String>, runnerName: String?) {
        self.id = id
        self.repository = repository
        self.status = status
        self.labels = labels
        self.runnerName = runnerName
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
