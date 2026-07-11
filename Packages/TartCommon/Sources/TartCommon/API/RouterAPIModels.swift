import Foundation

/// A single job as tracked by the router.
public struct RouterJobDTO: Codable {
    public let id: Int
    public let action: WorkflowAction
    public let labels: [String]
    /// Hostname of the executor this job was dispatched to, if any.
    public let sentToHost: String?
    public let receivedAt: Date
    public let sentAt: Date?

    public init(id: Int, action: WorkflowAction, labels: [String], sentToHost: String?, receivedAt: Date, sentAt: Date?) {
        self.id = id
        self.action = action
        self.labels = labels
        self.sentToHost = sentToHost
        self.receivedAt = receivedAt
        self.sentAt = sentAt
    }
}

/// Response for `GET /api/v1/jobs` on the router.
public struct RouterJobsResponse: Codable {
    public let jobs: [RouterJobDTO]

    public init(jobs: [RouterJobDTO]) {
        self.jobs = jobs
    }
}

/// An executor (host) as tracked by the router, including its last-polled status.
public struct RouterHostDTO: Codable {
    public let hostname: String
    public let url: String
    public let priority: Int
    public let cpuLimit: Int?
    public let memoryLimit: Int?
    public let reachable: Bool
    public let lastStatus: TartHostStatus?

    public init(
        hostname: String,
        url: String,
        priority: Int,
        cpuLimit: Int?,
        memoryLimit: Int?,
        reachable: Bool,
        lastStatus: TartHostStatus?
    ) {
        self.hostname = hostname
        self.url = url
        self.priority = priority
        self.cpuLimit = cpuLimit
        self.memoryLimit = memoryLimit
        self.reachable = reachable
        self.lastStatus = lastStatus
    }
}

/// Response for `GET /api/v1/hosts`.
public struct RouterHostsResponse: Codable {
    public let hosts: [RouterHostDTO]

    public init(hosts: [RouterHostDTO]) {
        self.hosts = hosts
    }
}

/// Response for `GET /api/v1/status` on the router.
public struct RouterStatusResponse: Codable {
    public let hostname: String
    public let pendingJobs: Int
    public let pendingJobsUnsent: Int
    public let pendingJobsQueued: Int
    public let availableVirtualMachines: Int
    public let availableHosts: Int

    public init(
        hostname: String,
        pendingJobs: Int,
        pendingJobsUnsent: Int,
        pendingJobsQueued: Int,
        availableVirtualMachines: Int,
        availableHosts: Int
    ) {
        self.hostname = hostname
        self.pendingJobs = pendingJobs
        self.pendingJobsUnsent = pendingJobsUnsent
        self.pendingJobsQueued = pendingJobsQueued
        self.availableVirtualMachines = availableVirtualMachines
        self.availableHosts = availableHosts
    }
}

/// A configured host as it appears in `GET /api/v1/settings` on the router.
public struct RouterHostConfigDTO: Codable {
    public let hostname: String
    public let url: String
    public let priority: Int
    public let cpuLimit: Int?
    public let memoryLimit: Int?

    public init(hostname: String, url: String, priority: Int, cpuLimit: Int?, memoryLimit: Int?) {
        self.hostname = hostname
        self.url = url
        self.priority = priority
        self.cpuLimit = cpuLimit
        self.memoryLimit = memoryLimit
    }
}

/// Response for `GET /api/v1/settings` on the router. Contains no secrets.
public struct RouterSettingsResponse: Codable {
    public let hostname: String
    public let labels: [String]
    public let port: Int
    public let loggingEndpoint: String?
    public let authEnabled: Bool
    public let hosts: [RouterHostConfigDTO]

    public init(
        hostname: String,
        labels: [String],
        port: Int,
        loggingEndpoint: String?,
        authEnabled: Bool,
        hosts: [RouterHostConfigDTO]
    ) {
        self.hostname = hostname
        self.labels = labels
        self.port = port
        self.loggingEndpoint = loggingEndpoint
        self.authEnabled = authEnabled
        self.hosts = hosts
    }
}
