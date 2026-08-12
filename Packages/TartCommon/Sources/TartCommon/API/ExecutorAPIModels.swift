import Foundation

/// Lifecycle bucket a job currently sits in on the executor.
public enum ExecutorJobState: String, Codable, Sendable {
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

/// Why a dispatch did not start a virtual machine. Absent when one was started.
public enum DispatchSkipReason: String, Codable {
    /// A virtual machine for this job id already exists on this executor. Never overridden by
    /// `force` — cancel the job first if a replacement machine is really wanted.
    case virtualMachineExists = "virtual_machine_exists"
    /// The job is already queued or in progress here. Overridden by `force`.
    case alreadyTracked = "already_tracked"
    /// The executor is already running its configured maximum number of machines. Overridden by
    /// `force`, which deliberately over-commits the host.
    case atCapacity = "at_capacity"
    /// The labels do not describe a job this executor can run.
    case labelMismatch = "label_mismatch"
    /// The router found no executor with capacity for the job. Router only.
    case noHostAvailable = "no_host_available"
}

/// Request body for `POST /api/v1/jobs/dispatch`.
public struct ExecutorDispatchRequest: Codable {
    public let id: Int
    /// The job's GitHub labels, **verbatim**. These become the runner's `--labels`, so any
    /// reordering, filtering, or normalisation produces a runner GitHub will not match, which
    /// leaves the job queued while the API reports success.
    public let labels: [String]
    /// Bypasses the already-tracked and capacity guards. Never bypasses the existing-VM guard.
    public let force: Bool?

    public init(id: Int, labels: [String], force: Bool?) {
        self.id = id
        self.labels = labels
        self.force = force
    }
}

/// Response for `POST /api/v1/jobs/dispatch` on the executor.
public struct ExecutorDispatchResponse: Codable {
    public let started: Bool
    public let jobId: Int
    public let hostname: String
    public let vmName: String?
    public let imageName: String?
    public let cpu: Int?
    public let memory: Int?
    public let forced: Bool
    public let reason: DispatchSkipReason?
    public let message: String?

    public init(
        started: Bool,
        jobId: Int,
        hostname: String,
        vmName: String? = nil,
        imageName: String? = nil,
        cpu: Int? = nil,
        memory: Int? = nil,
        forced: Bool = false,
        reason: DispatchSkipReason? = nil,
        message: String? = nil
    ) {
        self.started = started
        self.jobId = jobId
        self.hostname = hostname
        self.vmName = vmName
        self.imageName = imageName
        self.cpu = cpu
        self.memory = memory
        self.forced = forced
        self.reason = reason
        self.message = message
    }
}

/// A job GitHub currently reports as queued, annotated with what this executor would do with it.
public struct GitHubQueuedJobDTO: Codable {
    public let id: Int
    public let runId: Int
    public let name: String
    public let workflowName: String?
    /// `owner/repo`.
    public let repository: String
    public let htmlUrl: String?
    /// GitHub's label set, sorted for stable output but otherwise untouched.
    public let labels: [String]
    public let createdAt: Date
    /// Whether this executor's configured runner labels and image rule accept the job.
    public let matchesRunnerLabels: Bool
    /// Why the job was rejected, when `matchesRunnerLabels` is false.
    public let labelMismatchReason: String?
    public let imageName: String?
    public let cpu: Int?
    public let memory: Int?

    public init(
        id: Int,
        runId: Int,
        name: String,
        workflowName: String?,
        repository: String,
        htmlUrl: String?,
        labels: [String],
        createdAt: Date,
        matchesRunnerLabels: Bool,
        labelMismatchReason: String?,
        imageName: String?,
        cpu: Int?,
        memory: Int?
    ) {
        self.id = id
        self.runId = runId
        self.name = name
        self.workflowName = workflowName
        self.repository = repository
        self.htmlUrl = htmlUrl
        self.labels = labels
        self.createdAt = createdAt
        self.matchesRunnerLabels = matchesRunnerLabels
        self.labelMismatchReason = labelMismatchReason
        self.imageName = imageName
        self.cpu = cpu
        self.memory = memory
    }
}

/// Response for `GET /api/v1/github/queued-jobs`. A partial scan returns `200` with `warnings`
/// populated rather than an error, so a degraded scan is never mistaken for an empty queue.
public struct GitHubQueuedJobsResponse: Codable {
    public let hostname: String
    public let jobs: [GitHubQueuedJobDTO]
    public let scannedAt: Date
    public let repositoriesScanned: Int
    /// Whether the scan hit a repository cap, time budget, or rate-limit floor before finishing.
    public let truncated: Bool
    public let warnings: [String]
    public let rateLimitRemaining: Int?
    public let rateLimitResetAt: Date?

    public init(
        hostname: String,
        jobs: [GitHubQueuedJobDTO],
        scannedAt: Date,
        repositoriesScanned: Int,
        truncated: Bool,
        warnings: [String],
        rateLimitRemaining: Int?,
        rateLimitResetAt: Date?
    ) {
        self.hostname = hostname
        self.jobs = jobs
        self.scannedAt = scannedAt
        self.repositoriesScanned = repositoriesScanned
        self.truncated = truncated
        self.warnings = warnings
        self.rateLimitRemaining = rateLimitRemaining
        self.rateLimitResetAt = rateLimitResetAt
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
