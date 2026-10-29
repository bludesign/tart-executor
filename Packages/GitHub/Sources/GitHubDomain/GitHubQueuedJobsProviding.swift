import Foundation

public protocol GitHubQueuedJobsProviding: Sendable {
    /// Returns the queued jobs GitHub knows about. Implementations are expected to cache: pass
    /// `refresh` to force a fresh scan rather than accepting a cached snapshot.
    func queuedJobs(refresh: Bool) async throws -> GitHubQueuedJobsSnapshot

    /// Looks up one job directly. Failure means its state is unknown, not that it completed.
    func job(id: Int, repository: String) async throws -> GitHubJobStatus

    /// Cached display enrichment. Never use this method to decide whether to provision or cancel.
    func jobDetails(id: Int, repository: String) async throws -> GitHubJobStatus
}

public extension GitHubQueuedJobsProviding {
    func jobDetails(id: Int, repository: String) async throws -> GitHubJobStatus {
        try await job(id: id, repository: repository)
    }

    func job(id: Int, repository: String) async throws -> GitHubJobStatus {
        throw GitHubJobLookupError.unsupported
    }
}
