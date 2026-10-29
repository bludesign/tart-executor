import FlyingFox
import Foundation
import GitHubDomain
import TartCommon

extension ExecutorServer {
    func jobObservationsResponse(for request: HTTPRequest) async -> HTTPResponse {
        if let denied = authorizationFailure(for: request) { return denied }
        do {
            let body = try await request.bodyData
            let observations = try apiDecoder.decode(GitHubJobObservationsRequest.self, from: body)
            guard observations.jobs.count <= 1_000,
                  observations.jobs.allSatisfy({ context in
                      guard let id = Int(context.workflowJobId) else { return false }
                      return id > 0 && String(id) == context.workflowJobId
                  }) else {
                return .jsonError("Invalid job observations or batch limit exceeded", statusCode: .badRequest)
            }
            for context in observations.jobs { await jobHandler.observeJob(context) }
            return .json(["status": "observed"], encoder: apiEncoder)
        } catch {
            return .jsonError("Invalid job observations", statusCode: .badRequest)
        }
    }

    /// Background display enrichment. Scheduling lookups remain fresh and independent.
    func refreshJobMetadata() async {
        if await jobHandler.needsAttributionCleanup,
           let inventory = try? await virtualMachineProvider.listVirtualMachineDetails() {
            await jobHandler.confirmInventory(names: Set(inventory.map(\.name)))
        }
        guard let queuedJobsProvider else { return }
        if settings.routerUrl == nil, await jobHandler.jobStatus.virtualMachines > 0 {
            do {
                let snapshot = try await queuedJobsProvider.queuedJobs(refresh: false)
                for job in snapshot.runnerJobs { await jobHandler.observeJob(job.context) }
            } catch {
                logger.error("Executor Runner Observation Scan Failed", parameters: ["error": error.localizedDescription])
            }
        }
        let deadline = Date().addingTimeInterval(20)
        let jobs = await jobHandler.metadataJobs()
        for context in jobs.prefix(40) {
            guard !Task.isCancelled, Date() < deadline else { break }
            guard let id = Int(context.workflowJobId), let repository = context.repository else { continue }
            do {
                let details = try await queuedJobsProvider.jobDetails(id: id, repository: repository)
                await jobHandler.observeJob(details.context)
            } catch {
                var unavailable = context
                unavailable.warnings = ["GitHub metadata refresh failed: \(error.localizedDescription)"]
                unavailable.observedAt = Date()
                await jobHandler.observeJob(unavailable)
            }
        }
    }
}

extension GitHubJobStatus {
    var context: GitHubJobContext {
        GitHubJobContext(
            workflowJobId: String(id), workflowRunId: runId.map(String.init), repository: repository,
            name: name, workflowName: workflowName, htmlUrl: htmlUrl, runUrl: runUrl, runTitle: runTitle,
            runNumber: runNumber, runAttempt: runAttempt, event: event, actor: actor,
            headBranch: headBranch, headSha: headSha, status: status, conclusion: conclusion,
            runnerName: runnerName, createdAt: createdAt, startedAt: startedAt, completedAt: completedAt,
            observedAt: observedAt ?? Date(), source: "github_api", warnings: []
        )
    }
}
