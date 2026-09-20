import FlyingFox
import Foundation
import GitHubDomain
import TartCommon

extension ExecutorServer {
    /// Validates a workflow job's labels and hands it to the job handler. Shared by the webhook
    /// routes (`POST /` and `POST /router`) so the management API can never take a different
    /// path to a virtual machine than GitHub does.
    func handleWorkflowJob(_ workflowJob: WorkflowJob) async -> Bool {
        let pendingJob: ExecutorPendingJob
        do {
            pendingJob = try planner.makePendingJob(
                for: workflowJob,
                netBridgedAdapter: settings.netBridgedAdapter,
                isHeadless: settings.isHeadless
            )
        } catch {
            logPlanFailure(error, workflowJob: workflowJob)
            return false
        }

        logger.info("Executor Handle Workflow Job Received", parameters: [
            LogParameterKey.workflowJobId: "\(workflowJob.id)",
            LogParameterKey.action: workflowJob.action.rawValue,
            LogParameterKey.imageName: pendingJob.imageName,
            LogParameterKey.isInsecure: "\(pendingJob.isInsecure)",
            LogParameterKey.cpu: pendingJob.cpu.map { "\($0)" } ?? "default",
            LogParameterKey.memory: pendingJob.memory.map { "\($0)" } ?? "default"
        ])

        return await jobHandler.handle(pendingJob: pendingJob)
    }

    /// Handles `POST /api/v1/jobs/dispatch`: starts a machine for a job the executor never heard
    /// about, or heard about and lost.
    func dispatchResponse(for request: HTTPRequest) async -> HTTPResponse {
        let dispatchRequest: ExecutorDispatchRequest
        do {
            let bodyData = try await request.bodyData
            dispatchRequest = try apiDecoder.decode(ExecutorDispatchRequest.self, from: bodyData)
        } catch {
            return .jsonError("Invalid request body", statusCode: .badRequest)
        }
        guard !dispatchRequest.labels.isEmpty else {
            return .jsonError("labels must not be empty", statusCode: .badRequest)
        }

        let force = dispatchRequest.force ?? false
        let workflowJob = WorkflowJob(
            id: dispatchRequest.id,
            action: .queued,
            labels: Set(dispatchRequest.labels)
        )

        let pendingJob: ExecutorPendingJob
        do {
            pendingJob = try planner.makePendingJob(
                for: workflowJob,
                netBridgedAdapter: settings.netBridgedAdapter,
                isHeadless: settings.isHeadless
            )
        } catch {
            logPlanFailure(error, workflowJob: workflowJob)
            // 422 rather than 400: the body parsed fine, these labels just cannot run here.
            let response = ExecutorDispatchResponse(
                started: false,
                jobId: workflowJob.id,
                hostname: settings.hostname,
                forced: force,
                reason: .labelMismatch,
                message: error.localizedDescription
            )
            return .json(response, statusCode: .unprocessableContent, encoder: apiEncoder)
        }

        let outcome = await jobHandler.dispatch(pendingJob: pendingJob, force: force)
        switch outcome {
        case let .started(vmName):
            let response = ExecutorDispatchResponse(
                started: true,
                jobId: workflowJob.id,
                hostname: settings.hostname,
                vmName: vmName,
                imageName: pendingJob.imageName,
                cpu: pendingJob.cpu,
                memory: pendingJob.memory,
                forced: force
            )
            return .json(response, encoder: apiEncoder)
        case let .skippedVirtualMachineExists(vmName):
            return .json(
                ExecutorDispatchResponse(
                    started: false,
                    jobId: workflowJob.id,
                    hostname: settings.hostname,
                    vmName: vmName,
                    forced: force,
                    reason: .virtualMachineExists,
                    message: "A virtual machine for this job already exists. Cancel the job first to replace it."
                ),
                statusCode: .conflict,
                encoder: apiEncoder
            )
        case let .skippedAlreadyTracked(state):
            return .json(
                ExecutorDispatchResponse(
                    started: false,
                    jobId: workflowJob.id,
                    hostname: settings.hostname,
                    forced: force,
                    reason: .alreadyTracked,
                    message: "The job is already tracked as \(state.rawValue). Pass force to start a machine anyway."
                ),
                statusCode: .conflict,
                encoder: apiEncoder
            )
        case let .skippedAtCapacity(active, limit):
            return .json(
                ExecutorDispatchResponse(
                    started: false,
                    jobId: workflowJob.id,
                    hostname: settings.hostname,
                    forced: force,
                    reason: .atCapacity,
                    message: "Already running \(active) of \(limit) machines. Pass force to over-commit the host."
                ),
                statusCode: .conflict,
                encoder: apiEncoder
            )
        case let .skippedInsufficientResources(cpuUsed, cpuLimit, memoryUsed, memoryLimit):
            return .json(
                ExecutorDispatchResponse(
                    started: false,
                    jobId: workflowJob.id,
                    hostname: settings.hostname,
                    cpu: pendingJob.cpu,
                    memory: pendingJob.memory,
                    forced: force,
                    reason: .atCapacity,
                    message: "Insufficient aggregate resources: CPU \(cpuUsed)/\(cpuLimit), memory \(memoryUsed)/\(memoryLimit) MB."
                ),
                statusCode: .conflict,
                encoder: apiEncoder
            )
        }
    }

    /// Maps a job's GitHub labels to what this executor would do with it, for the
    /// `GET /api/v1/github/queued-jobs` response.
    func queuedJobDTO(for job: GitHubQueuedJob) -> GitHubQueuedJobDTO {
        let workflowJob = WorkflowJob(id: job.id, action: .queued, labels: job.labels)
        var plan: ExecutorJobPlan?
        var mismatchReason: String?
        do {
            plan = try planner.plan(for: workflowJob)
        } catch {
            mismatchReason = error.localizedDescription
        }
        return GitHubQueuedJobDTO(
            id: job.id,
            runId: job.runId,
            name: job.name,
            workflowName: job.workflowName,
            repository: job.repositoryFullName,
            htmlUrl: job.htmlURL,
            labels: job.labels.sorted(),
            createdAt: job.createdAt,
            matchesRunnerLabels: plan != nil,
            labelMismatchReason: mismatchReason,
            imageName: plan?.imageName,
            cpu: plan?.cpu,
            memory: plan?.memory
        )
    }

    private func logPlanFailure(_ error: Error, workflowJob: WorkflowJob) {
        switch error {
        case ExecutorJobPlanError.missingRunnerLabels:
            logger.error("Executor Handle Workflow Job Skipped For Labels", parameters: [
                LogParameterKey.workflowJobId: "\(workflowJob.id)",
                LogParameterKey.jobLabels: workflowJob.labels.joined(separator: ","),
                LogParameterKey.tartLabels: gitHubRunnerLabels.joined(separator: ",")
            ])
        case let ExecutorJobPlanError.ambiguousImageLabel(extra):
            logger.error("Executor Handle Workflow Job Skipped For Extra Labels", parameters: [
                LogParameterKey.workflowJobId: "\(workflowJob.id)",
                LogParameterKey.extraLabels: extra.joined(separator: ","),
                LogParameterKey.expectedCount: "1",
                LogParameterKey.actualCount: "\(extra.count)"
            ])
        default:
            logger.error("Executor Handle Workflow Job Skipped", parameters: [
                LogParameterKey.workflowJobId: "\(workflowJob.id)",
                LogParameterKey.error: error.localizedDescription
            ])
        }
    }
}
