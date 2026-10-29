import Foundation
import TartCommon

extension RouterJobHandler {
    func refreshRunnerObservations(using source: RouterGitHubReconciling) async {
        do {
            let snapshot = try await source.queuedJobs()
            await broadcastObservations(snapshot.runnerJobs ?? [])
        } catch {
            logger.error("Router Runner Observation Scan Failed", parameters: ["error": error.localizedDescription])
        }
    }

    /// Best-effort fanout, independent of the scheduler's provisional host attribution.
    func broadcastObservations(_ contexts: [GitHubJobContext]) async {
        let observations = contexts.filter { context in
            context.runnerName?.isEmpty == false && (context.status == "in_progress" || context.status == "completed")
        }
        guard !observations.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask { [session, executorApiToken, logger] in
                    do {
                        // A bounded body also keeps large installations from overwhelming an executor.
                        for start in stride(from: 0, to: observations.count, by: 1_000) {
                            let batch = Array(observations[start..<min(start + 1_000, observations.count)])
                            var request = URLRequest(
                                url: host.url.appending(path: "/api/v1/github/job-observations"), timeoutInterval: 5
                            )
                            request.httpMethod = "POST"
                            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            if let executorApiToken {
                                request.setValue("Bearer \(executorApiToken)", forHTTPHeaderField: "Authorization")
                            }
                            request.httpBody = try JSONEncoder.api.encode(GitHubJobObservationsRequest(jobs: batch))
                            let (_, response) = try await session.data(for: request)
                            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                                throw URLError(.badServerResponse)
                            }
                        }
                    } catch {
                        logger.error("Executor Runner Observations Unavailable", parameters: [
                            "hostname": host.hostname, "error": error.localizedDescription
                        ])
                    }
                }
            }
        }
    }
}
