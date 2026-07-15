import Foundation

/// Lifecycle bucket a job currently sits in on the executor.
public enum ExecutorJobState: String, Codable {
    /// Queued, waiting for a free virtual-machine slot.
    case pending
    /// Reported by GitHub as running.
    case inProgress = "in_progress"
    /// A virtual machine still exists for the job even though it is no longer tracked as
    /// pending/in-progress (e.g. finishing or shutting down).
    case active
}

/// A single job as tracked by the executor.
public struct ExecutorJobDTO: Codable {
    public let id: Int
    public let action: WorkflowAction
    public let state: ExecutorJobState
    public let labels: [String]
    public let didStart: Bool
    public let cpu: Int?
    public let memory: Int?
    public let imageName: String?
    public let vmName: String?
    public let vmUUID: String?
    public let queuedAt: Date?
    public let startedAt: Date?

    public init(
        id: Int,
        action: WorkflowAction,
        state: ExecutorJobState,
        labels: [String],
        didStart: Bool,
        cpu: Int?,
        memory: Int?,
        imageName: String?,
        vmName: String?,
        vmUUID: String?,
        queuedAt: Date?,
        startedAt: Date?
    ) {
        self.id = id
        self.action = action
        self.state = state
        self.labels = labels
        self.didStart = didStart
        self.cpu = cpu
        self.memory = memory
        self.imageName = imageName
        self.vmName = vmName
        self.vmUUID = vmUUID
        self.queuedAt = queuedAt
        self.startedAt = startedAt
    }
}

/// Response for `GET /api/v1/jobs`.
public struct ExecutorJobsResponse: Codable {
    public let jobs: [ExecutorJobDTO]

    public init(jobs: [ExecutorJobDTO]) {
        self.jobs = jobs
    }
}

/// Response for `GET /api/v1/status` (richer than the root `/status`).
public struct ExecutorStatusResponse: Codable {
    public let hostname: String
    public let inProgressJobs: Int
    public let pendingJobs: Int
    public let startedPendingJobs: Int
    public let activeVirtualMachines: Int
    public let virtualMachineLimit: Int
    public let cpuLimit: Int
    public let cpuUsed: Int
    public let totalMemory: Int
    public let memoryUsed: Int
    /// Total capacity of the volume backing the Tart home directory, in bytes.
    public let diskTotalBytes: Int64?
    /// Available capacity of the Tart home volume, in bytes.
    public let diskFreeBytes: Int64?
    /// Used capacity of the Tart home volume, in bytes.
    public let diskUsedBytes: Int64?

    public init(
        hostname: String,
        inProgressJobs: Int,
        pendingJobs: Int,
        startedPendingJobs: Int,
        activeVirtualMachines: Int,
        virtualMachineLimit: Int,
        cpuLimit: Int,
        cpuUsed: Int,
        totalMemory: Int,
        memoryUsed: Int,
        diskTotalBytes: Int64? = nil,
        diskFreeBytes: Int64? = nil,
        diskUsedBytes: Int64? = nil
    ) {
        self.hostname = hostname
        self.inProgressJobs = inProgressJobs
        self.pendingJobs = pendingJobs
        self.startedPendingJobs = startedPendingJobs
        self.activeVirtualMachines = activeVirtualMachines
        self.virtualMachineLimit = virtualMachineLimit
        self.cpuLimit = cpuLimit
        self.cpuUsed = cpuUsed
        self.totalMemory = totalMemory
        self.memoryUsed = memoryUsed
        self.diskTotalBytes = diskTotalBytes
        self.diskFreeBytes = diskFreeBytes
        self.diskUsedBytes = diskUsedBytes
    }
}

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

    public init(
        name: String,
        ipAddress: String?,
        jobId: Int?,
        managedByExecutor: Bool,
        state: String? = nil,
        running: Bool? = nil,
        sizeGB: Double? = nil,
        diskGB: Double? = nil,
        source: String? = nil
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
    }
}

/// Response for `GET /api/v1/vms`.
public struct VirtualMachineListResponse: Codable {
    public let virtualMachines: [VirtualMachineDTO]

    public init(virtualMachines: [VirtualMachineDTO]) {
        self.virtualMachines = virtualMachines
    }
}

/// Request body for `POST /api/v1/images/pull`.
public struct ImagePullRequest: Codable {
    public let name: String
    public let isInsecure: Bool?

    public init(name: String, isInsecure: Bool?) {
        self.name = name
        self.isInsecure = isInsecure
    }
}

/// Response for `GET /api/v1/settings` on the executor. Secrets are never included; their
/// presence is reported as booleans instead.
public struct ExecutorSettingsResponse: Codable {
    public let hostname: String
    public let numberOfMachines: Int
    public let runnerLabels: String
    public let webhookPort: Int
    public let routerUrl: String?
    public let localUrl: String?
    public let isHeadless: Bool
    public let isInsecure: Bool
    public let insecureDomains: [String]
    public let netBridgedAdapter: String?
    public let defaultCpu: Int?
    public let defaultMemory: Int?
    public let cpuLimit: Int
    public let totalMemory: Int
    public let loggingEndpoint: String?
    public let authEnabled: Bool

    public init(
        hostname: String,
        numberOfMachines: Int,
        runnerLabels: String,
        webhookPort: Int,
        routerUrl: String?,
        localUrl: String?,
        isHeadless: Bool,
        isInsecure: Bool,
        insecureDomains: [String],
        netBridgedAdapter: String?,
        defaultCpu: Int?,
        defaultMemory: Int?,
        cpuLimit: Int,
        totalMemory: Int,
        loggingEndpoint: String?,
        authEnabled: Bool
    ) {
        self.hostname = hostname
        self.numberOfMachines = numberOfMachines
        self.runnerLabels = runnerLabels
        self.webhookPort = webhookPort
        self.routerUrl = routerUrl
        self.localUrl = localUrl
        self.isHeadless = isHeadless
        self.isInsecure = isInsecure
        self.insecureDomains = insecureDomains
        self.netBridgedAdapter = netBridgedAdapter
        self.defaultCpu = defaultCpu
        self.defaultMemory = defaultMemory
        self.cpuLimit = cpuLimit
        self.totalMemory = totalMemory
        self.loggingEndpoint = loggingEndpoint
        self.authEnabled = authEnabled
    }
}
