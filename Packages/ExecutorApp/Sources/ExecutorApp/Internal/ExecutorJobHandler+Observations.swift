import Foundation
import TartCommon

extension ExecutorJobHandler {
    /// Observation-only: no queue, capacity, or task mutations occur here.
    func observeJob(_ context: GitHubJobContext) {
        guard let id = Int(context.workflowJobId), id > 0 else { return }
        let knownJob = pendingJobs[id] != nil || inProgressJobs[id] != nil
            || activeJobs.values.contains { $0.jobId == id } || createdJobIDs.values.contains(id)
        let runnerName = context.runnerName.flatMap { name in
            let registered = createdJobIDs[name] != nil || activeJobs.values.contains { $0.vmName == name }
            return registered ? name : nil
        }
        guard knownJob || runnerName != nil else { return }
        if let runnerName, let existing = assignedJobs[runnerName], existing.workflowJobId != context.workflowJobId {
            if knownJob { rememberContext(context) }
            return
        }
        rememberContext(context)
        guard let runnerName, context.status == "in_progress" || context.status == "completed" else { return }
        if let existing = assignedJobs[runnerName] {
            if existing.workflowJobId == context.workflowJobId {
                assignedJobs[runnerName] = existing.merging(context)
                return
            }
        }
        assignedJobs[runnerName] = context
    }

    func rememberContext(_ context: GitHubJobContext) {
        guard let id = Int(context.workflowJobId) else { return }
        jobContexts[id] = jobContexts[id].map { $0.merging(context) } ?? context
    }

    func attribution(for name: String) -> (createdFor: GitHubJobContext?, assigned: GitHubJobContext?) {
        let creatorID = createdJobIDs[name] ?? activeJobs.values.first { $0.vmName == name }?.jobId
        return (creatorID.flatMap { jobContexts[$0] }, assignedJobs[name])
    }

    func metadataJobs() -> [GitHubJobContext] {
        var byID = jobContexts
        for context in assignedJobs.values {
            if let id = Int(context.workflowJobId) { byID[id] = context }
        }
        let activeIDs = Set(activeJobs.values.map(\.jobId)).union(createdJobIDs.values)
            .union(assignedJobs.values.compactMap { Int($0.workflowJobId) })
        let active = byID.filter { activeIDs.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
        let waiting = byID.filter { !activeIDs.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
        func rotated(_ contexts: [GitHubJobContext], cursor: inout Int, count: Int) -> [GitHubJobContext] {
            guard !contexts.isEmpty, count > 0 else { return [] }
            let offset = cursor % contexts.count
            cursor = (offset + count) % contexts.count
            return Array((contexts[offset...] + contexts[..<offset]).prefix(count))
        }
        let selected = rotated(active, cursor: &metadataRefreshCursor, count: 40)
        return selected + rotated(waiting, cursor: &metadataWaitingRefreshCursor, count: 40 - selected.count)
    }

    var needsAttributionCleanup: Bool {
        createdJobIDs.keys.contains { name in !activeJobs.values.contains { $0.vmName == name } }
    }

    /// Only a successful inventory can prove a VM is gone. Task cleanup can fail while
    /// leaving a running VM behind, so preserve its known runner binding until then.
    func confirmInventory(names: Set<String>) {
        let retainedNames = names.union(activeJobs.values.map(\.vmName))
        createdJobIDs = createdJobIDs.filter { retainedNames.contains($0.key) }
        assignedJobs = assignedJobs.filter { retainedNames.contains($0.key) }
        pruneContexts()
    }

    func pruneContexts() {
        let retained = Set(pendingJobs.keys).union(inProgressJobs.keys)
            .union(activeJobs.values.map(\.jobId)).union(createdJobIDs.values)
            .union(assignedJobs.values.compactMap { Int($0.workflowJobId) })
        jobContexts = jobContexts.filter { retained.contains($0.key) }
    }
}
