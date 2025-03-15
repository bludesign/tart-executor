import Foundation
import TartCommon

final class ExecutorPendingJob: Identifiable {
    let workflowJob: WorkflowJob
    let imageName: String
    let netBridgedAdapter: String?
    let isInsecure: Bool
    let isHeadless: Bool
    let cpu: Int?
    let memory: Int?
    var didStart = false

    var id: Int {
        workflowJob.id
    }

    var action: WorkflowAction {
        workflowJob.action
    }

    init(
        workflowJob: WorkflowJob,
        imageName: String,
        netBridgedAdapter: String?,
        isInsecure: Bool,
        isHeadless: Bool,
        cpu: Int?,
        memory: Int?
    ) {
        self.workflowJob = workflowJob
        self.imageName = imageName
        self.netBridgedAdapter = netBridgedAdapter
        self.isInsecure = isInsecure
        self.isHeadless = isHeadless
        self.cpu = cpu
        self.memory = memory
    }
}
