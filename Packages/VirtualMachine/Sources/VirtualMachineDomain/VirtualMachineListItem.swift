import Foundation

/// A single local Tart virtual machine / image as reported by `tart list`, carrying the extra
/// detail exposed by `tart list --format json`. Everything beyond `name` is optional so an older
/// Tart (or the names-only fallback) still yields a valid item.
public struct VirtualMachineListItem: Sendable, Equatable {
    public let name: String
    /// Origin as reported by Tart, e.g. `local`.
    public let source: String?
    /// Lifecycle state as reported by Tart, e.g. `running`, `stopped`, `suspended`.
    public let state: String?
    /// Whether the machine is currently running.
    public let running: Bool?
    /// Actual on-disk usage in gigabytes.
    public let sizeGB: Double?
    /// Provisioned disk size in gigabytes.
    public let diskGB: Double?
    public let cpu: Int?
    /// Configured memory in MiB, matching `tart get`.
    public let memory: Int?
    public let os: String?

    public init(
        name: String,
        source: String? = nil,
        state: String? = nil,
        running: Bool? = nil,
        sizeGB: Double? = nil,
        diskGB: Double? = nil,
        cpu: Int? = nil, memory: Int? = nil, os: String? = nil
    ) {
        self.name = name
        self.source = source
        self.state = state
        self.running = running
        self.sizeGB = sizeGB
        self.diskGB = diskGB
        self.cpu = cpu
        self.memory = memory
        self.os = os
    }
}

/// Capacity of the volume backing the Tart home directory.
public struct TartDiskUsage: Sendable, Equatable {
    public let totalBytes: Int64
    public let freeBytes: Int64

    public init(totalBytes: Int64, freeBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    /// Bytes in use, never negative.
    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
}
