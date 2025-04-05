import Foundation

struct TartHostStatus: Codable {
    let inProgressJobs: Int
    let pendingJobs: Int
    let startedPendingJobs: Int
    let activeVirtualMachines: Int
    let virtualMachineLimit: Int
    let cpuLimit: Int
    let cpuUsed: Int
    let totalMemory: Int
    let memoryUsed: Int

    var totalJobs: Int {
        inProgressJobs + pendingJobs
    }
}
