import Foundation

/// A Tart virtual machine / local image as seen by `tart list`. The fields after
/// `managedByExecutor` come from `tart list --format json` and are absent on older Tart builds.
public struct VirtualMachineDTO: Codable {
    public let name: String
    public let ipAddress: String?
    public let jobId: Int?
    public let managedByExecutor: Bool
    /// Lifecycle state reported by Tart, e.g. `running`, `stopped`, `suspended`.
    public let state: String?
    /// Whether the machine is currently running.
    public let running: Bool?
    /// Actual on-disk usage in gigabytes.
    public let sizeGB: Double?
    /// Provisioned disk size in gigabytes.
    public let diskGB: Double?
    /// Origin as reported by Tart, e.g. `local`.
    public let source: String?
    public let createdForJob: GitHubJobContext?
    public let assignedJob: GitHubJobContext?
    public let cpu: Int?
    public let memory: Int?
    public let os: String?

    public init(
        name: String,
        ipAddress: String?,
        jobId: Int?,
        managedByExecutor: Bool,
        state: String? = nil,
        running: Bool? = nil,
        sizeGB: Double? = nil,
        diskGB: Double? = nil,
        source: String? = nil,
        createdForJob: GitHubJobContext? = nil,
        assignedJob: GitHubJobContext? = nil,
        cpu: Int? = nil, memory: Int? = nil, os: String? = nil
    ) {
        self.name = name
        self.ipAddress = ipAddress
        self.jobId = jobId
        self.managedByExecutor = managedByExecutor
        self.state = state
        self.running = running
        self.sizeGB = sizeGB
        self.diskGB = diskGB
        self.source = source
        self.createdForJob = createdForJob
        self.assignedJob = assignedJob
        self.cpu = cpu
        self.memory = memory
        self.os = os
    }
}

/// Response for `GET /api/v1/vms`.
public struct VirtualMachineListResponse: Codable {
    public let virtualMachines: [VirtualMachineDTO]

    public init(virtualMachines: [VirtualMachineDTO]) {
        self.virtualMachines = virtualMachines
    }
}
