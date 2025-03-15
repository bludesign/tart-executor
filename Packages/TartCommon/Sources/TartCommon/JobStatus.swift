import Foundation

public struct JobStatus {
    public let inProgressJobs: Int
    public let pendingJobs: Int
    public let startedPendingJobs: Int
    public let virtualMachines: Int
    public let cpuUsed: Int
    public let memoryUsed: Int

    public init(inProgressJobs: Int, pendingJobs: Int, startedPendingJobs: Int, virtualMachines: Int, cpuUsed: Int, memoryUsed: Int) {
        self.inProgressJobs = inProgressJobs
        self.pendingJobs = pendingJobs
        self.startedPendingJobs = startedPendingJobs
        self.virtualMachines = virtualMachines
        self.cpuUsed = cpuUsed
        self.memoryUsed = memoryUsed
    }
}
