import FlyingFox
import Foundation
import TartCommon

final class RouterPendingJob: Identifiable {
    let id: Int
    var workflowJob: WorkflowJob
    let headers: [HTTPHeader: String]
    let bodyData: Data
    /// When set, only this executor is eligible. Set by a manual dispatch that names a host;
    /// webhooks never set it. Pinning through `hostCanRun` reuses the normal placement loop
    /// rather than adding a second, unauthenticated path to an executor.
    let pinnedHostname: String?
    let receivedAt = Date()
    private(set) var sentAt: Date?
    var sentToHost: TartHost? {
        didSet {
            sentAt = sentToHost != nil ? Date() : nil
        }
    }

    init(workflowJob: WorkflowJob, headers: [HTTPHeader: String], bodyData: Data, pinnedHostname: String?) {
        self.id = workflowJob.id
        self.workflowJob = workflowJob
        self.headers = headers
        self.bodyData = bodyData
        self.pinnedHostname = pinnedHostname
    }

    func resourceRequirements(for status: TartHostStatus) -> ResourceRequirements {
        ResourceRequirements(
            cpu: workflowJob.cpu ?? status.defaultCpu,
            memory: workflowJob.memory ?? status.defaultMemory
        )
    }

    func hostCanRun(_ host: TartHost, requirements: ResourceRequirements) -> Bool {
        if let pinnedHostname, host.hostname != pinnedHostname {
            return false
        } else if let jobMemory = requirements.memory, let hostMemory = host.memoryLimit, jobMemory > hostMemory {
            return false
        } else if let jobCpu = requirements.cpu, let hostCpu = host.cpuLimit, jobCpu > hostCpu {
            return false
        } else {
            return true
        }
    }
}
