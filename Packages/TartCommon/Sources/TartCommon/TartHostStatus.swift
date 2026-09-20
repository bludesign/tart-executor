import Foundation

public struct TartHostStatus: Codable {
    public let inProgressJobs: Int
    public let pendingJobs: Int
    public let startedPendingJobs: Int
    public var activeVirtualMachines: Int
    public let virtualMachineLimit: Int
    public let cpuLimit: Int
    public var cpuUsed: Int
    public let totalMemory: Int
    public var memoryUsed: Int
    /// Per-VM defaults used when a workflow omits an explicit resource label.
    /// Optional for compatibility with older executors.
    public let defaultCpu: Int?
    public let defaultMemory: Int?

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
        memoryUsed: Int,
        defaultCpu: Int? = nil,
        defaultMemory: Int? = nil
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
        self.defaultCpu = defaultCpu
        self.defaultMemory = defaultMemory
    }

    public var resourceCapacity: ResourceCapacity {
        ResourceCapacity(
            cpuLimit: cpuLimit,
            cpuUsed: cpuUsed,
            memoryLimit: totalMemory,
            memoryUsed: memoryUsed
        )
    }

    public mutating func reserve(_ requirements: ResourceRequirements) {
        if let cpu = requirements.cpu {
            cpuUsed += cpu
        }
        if let memory = requirements.memory {
            memoryUsed += memory
        }
    }
}
