import Foundation

public struct TartHostStatus: Codable {
    public let inProgressJobs: Int
    public let pendingJobs: Int
    public let startedPendingJobs: Int
    public var activeVirtualMachines: Int
    public let virtualMachineLimit: Int
    public let cpuLimit: Int
    public let cpuUsed: Int
    public let totalMemory: Int
    public let memoryUsed: Int

    public var totalJobs: Int {
        inProgressJobs + pendingJobs
    }

    public init(
        inProgressJobs: Int,
        pendingJobs: Int,
        startedPendingJobs: Int,
        activeVirtualMachines: Int,
        virtualMachineLimit: Int,
        cpuLimit: Int,
        cpuUsed: Int,
        totalMemory: Int,
        memoryUsed: Int
    ) {
        self.inProgressJobs = inProgressJobs
        self.pendingJobs = pendingJobs
        self.startedPendingJobs = startedPendingJobs
        self.activeVirtualMachines = activeVirtualMachines
        self.virtualMachineLimit = virtualMachineLimit
        self.cpuLimit = cpuLimit
        self.cpuUsed = cpuUsed
        self.totalMemory = totalMemory
        self.memoryUsed = memoryUsed
    }
}
