import Foundation

public protocol GitHubQueuedJobsProviding: Sendable {
    /// Returns the queued jobs GitHub knows about. Implementations are expected to cache: pass
    /// `refresh` to force a fresh scan rather than accepting a cached snapshot.
    func queuedJobs(refresh: Bool) async throws -> GitHubQueuedJobsSnapshot

    /// Looks up one job directly. Failure means its state is unknown, not that it completed.
    func job(id: Int, repository: String) async throws -> GitHubJobStatus
}

public extension GitHubQueuedJobsProviding {
    func job(id: Int, repository: String) async throws -> GitHubJobStatus {
        throw GitHubJobLookupError.unsupported
    }
}
