import FlyingFox
import Foundation
import GitHubDomain
import TartCommon

extension ExecutorServer {
    func gitHubJobStatusResponse(for request: HTTPRequest) async -> HTTPResponse {
        guard let id = request.routeParameters["id", of: Int.self], id > 0 else {
            return .jsonError("Invalid job id", statusCode: .badRequest)
        }
        guard let repository = request.query["repository"], GitHubJobStatus.isValidRepository(repository) else {
            return .jsonError("repository must be an owner/repository name", statusCode: .badRequest)
        }
        guard let queuedJobsProvider else {
            return .jsonError("GitHub scanning is not configured", statusCode: .serviceUnavailable)
        }
        do {
            let job = try await queuedJobsProvider.job(id: id, repository: repository)
            guard job.id == id, job.repository == repository else {
                return .jsonError("GitHub returned a different job", statusCode: .badGateway)
            }
            return .json(GitHubJobStatusDTO(
                id: job.id,
                repository: job.repository,
                status: job.status,
                labels: job.labels.sorted(),
                runnerName: job.runnerName
            ), encoder: apiEncoder)
        } catch {
            return .jsonError("Failed to look up GitHub job: \(error.localizedDescription)", statusCode: .badGateway)
        }
    }
}
