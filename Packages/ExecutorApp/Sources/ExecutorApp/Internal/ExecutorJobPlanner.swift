import Foundation
import TartCommon

/// Everything the executor derives from a workflow job's labels before a virtual machine can be
/// created for it.
struct ExecutorJobPlan: Sendable {
    let imageName: String
    let cpu: Int?
    let memory: Int?
    let isInsecure: Bool
}

enum ExecutorJobPlanError: LocalizedError, Sendable {
    /// The job does not carry every label this executor is configured to answer for.
    case missingRunnerLabels(required: Set<String>, actual: Set<String>)
    /// After removing the configured labels and the `cpu:`/`memory:` overrides, the job must be
    /// left with exactly one label: the image to clone.
    case ambiguousImageLabel(extra: Set<String>)

    var errorDescription: String? {
        switch self {
        case let .missingRunnerLabels(required, actual):
            let requiredLabels = required.sorted().joined(separator: ",")
            let actualLabels = actual.sorted().joined(separator: ",")
            return "Job labels (\(actualLabels)) do not contain the configured runner labels (\(requiredLabels))"
        case let .ambiguousImageLabel(extra):
            let extraLabels = extra.sorted().joined(separator: ",")
            return "Expected exactly 1 image label, found \(extra.count) (\(extraLabels))"
        }
    }
}

/// Turns a `WorkflowJob` into an `ExecutorPendingJob`, applying the same label rules the webhook
/// path has always applied. Kept free of side effects and of actor isolation so the webhook
/// handler, the dispatch endpoint, and the GitHub scan mapper can all share one implementation.
struct ExecutorJobPlanner: Sendable {
    let runnerLabels: Set<String>
    let defaultCpu: Int?
    let defaultMemory: Int?
    let isInsecure: Bool
    let insecureDomains: [String]

    func plan(for workflowJob: WorkflowJob) throws -> ExecutorJobPlan {
        guard runnerLabels.isSubset(of: workflowJob.labels) else {
            throw ExecutorJobPlanError.missingRunnerLabels(required: runnerLabels, actual: workflowJob.labels)
        }

        let workflowSet = workflowJob.filteredLabels.subtracting(runnerLabels)
        guard workflowSet.count == 1, let imageName = workflowSet.first else {
            throw ExecutorJobPlanError.ambiguousImageLabel(extra: workflowSet)
        }

        let imageInsecure = insecureDomains.contains { insecureDomain in
            imageName.contains(insecureDomain)
        }

        return ExecutorJobPlan(
            imageName: imageName,
            cpu: workflowJob.cpu ?? defaultCpu,
            memory: workflowJob.memory ?? defaultMemory,
            isInsecure: isInsecure || imageInsecure
        )
    }

    func makePendingJob(
        for workflowJob: WorkflowJob,
        netBridgedAdapter: String?,
        isHeadless: Bool
    ) throws -> ExecutorPendingJob {
        let plan = try plan(for: workflowJob)
        return ExecutorPendingJob(
            workflowJob: workflowJob,
            imageName: plan.imageName,
            netBridgedAdapter: netBridgedAdapter,
            isInsecure: plan.isInsecure,
            isHeadless: isHeadless,
            cpu: plan.cpu,
            memory: plan.memory
        )
    }
}
