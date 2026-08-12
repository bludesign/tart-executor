import Foundation

public protocol GitHubQueuedJobsProviding: Sendable {
    /// Returns the queued jobs GitHub knows about. Implementations are expected to cache: pass
    /// `refresh` to force a fresh scan rather than accepting a cached snapshot.
    func queuedJobs(refresh: Bool) async throws -> GitHubQueuedJobsSnapshot
}
