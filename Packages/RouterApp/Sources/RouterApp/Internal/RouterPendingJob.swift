import FlyingFox
import Foundation
import TartCommon

final class RouterPendingJob: Identifiable {
    let id: Int
    var workflowJob: WorkflowJob
    let headers: [HTTPHeader: String]
    let bodyData: Data
    var sentToHost: TartHost?

    init(workflowJob: WorkflowJob, headers: [HTTPHeader: String], bodyData: Data) {
        self.id = workflowJob.id
        self.workflowJob = workflowJob
        self.headers = headers
        self.bodyData = bodyData
    }

    func hostCanRun(_ host: TartHost) -> Bool {
        if let jobMemory = workflowJob.memory, let hostMemory = host.memoryLimit, jobMemory > hostMemory {
            return false
        } else if let jobCpu = workflowJob.cpu, let hostCpu = host.cpuLimit, jobCpu > hostCpu {
            return false
        } else {
            return true
        }
    }
}
