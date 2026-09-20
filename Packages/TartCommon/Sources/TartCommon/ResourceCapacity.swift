public struct ResourceRequirements: Equatable, Sendable {
    public let cpu: Int?
    public let memory: Int?

    public init(cpu: Int?, memory: Int?) {
        self.cpu = cpu
        self.memory = memory
    }
}

public struct ResourceCapacity: Equatable, Sendable {
    public let cpuLimit: Int
    public let cpuUsed: Int
    public let memoryLimit: Int
    public let memoryUsed: Int

    public init(cpuLimit: Int, cpuUsed: Int, memoryLimit: Int, memoryUsed: Int) {
        self.cpuLimit = cpuLimit
        self.cpuUsed = cpuUsed
        self.memoryLimit = memoryLimit
        self.memoryUsed = memoryUsed
    }

    /// Unknown requirements are intentionally ignored so existing image-default workflows
    /// retain their previous behavior.
    public func canFit(_ requirements: ResourceRequirements) -> Bool {
        if let cpu = requirements.cpu, cpu < 0 || cpu > max(0, cpuLimit - cpuUsed) {
            return false
        }
        if let memory = requirements.memory, memory < 0 || memory > max(0, memoryLimit - memoryUsed) {
            return false
        }
        return true
    }
}
