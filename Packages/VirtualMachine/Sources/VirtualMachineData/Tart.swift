import Foundation
import ShellDomain
import VirtualMachineDomain

public final class Tart {
    private let homeProvider: TartHomeProvider
    private let shell: Shell
    private var environment: [String: String]? {
        guard let homeFolderUrl = homeProvider.homeFolderUrl else {
            return nil
        }
        return ["TART_HOME": homeFolderUrl.path(percentEncoded: false)]
    }

    public init(homeProvider: TartHomeProvider, shell: Shell) {
        self.homeProvider = homeProvider
        self.shell = shell
    }

    public func pull(sourceName: String, isInsecure: Bool) async throws {
        var arguments: [String] = ["pull", sourceName]
        if isInsecure {
            arguments.append("--insecure")
        }
        try await executeCommand(withArguments: arguments)
    }

    public func setCpu(name: String, cpu: Int) async throws {
        let arguments: [String] = ["set", name, "--cpu=\(cpu)"]
        try await executeCommand(withArguments: arguments)
    }

    public func setMemory(name: String, memory: Int) async throws {
        let arguments: [String] = ["set", name, "--memory=\(memory)"]
        try await executeCommand(withArguments: arguments)
    }

    public func clone(sourceName: String, newName: String, isInsecure: Bool) async throws {
        var arguments: [String] = ["clone", sourceName, newName]
        if isInsecure {
            arguments.append("--insecure")
        }
        try await executeCommand(withArguments: arguments)
    }

    public func run(name: String, netBridgedAdapter: String?, isHeadless: Bool) async throws {
        var arguments: [String] = ["run", name]
        if let netBridgedAdapter {
            arguments.append("--net-bridged=\(netBridgedAdapter)")
        }
        if isHeadless {
            arguments.append("--no-graphics")
        }
        try await executeCommand(withArguments: arguments)
    }

    public func delete(name: String) async throws {
        _ = try? await executeCommand(withArguments: ["stop", name])
        try await executeCommand(withArguments: ["delete", name])
    }

    public func list() async throws -> [String] {
        let result = try await executeCommand(withArguments: ["list", "-q", "--source", "local"])
        return result.split(separator: "\n").map(String.init)
    }

    /// Lists local VMs/images with state/size/source via `tart list --format json`. Falls back to
    /// the names-only listing when this Tart build doesn't support JSON output or returns something
    /// we can't decode, so the caller always gets at least the machine names.
    public func listDetailed() async throws -> [VirtualMachineListItem] {
        let json: String
        do {
            json = try await executeCommand(withArguments: ["list", "--format", "json", "--source", "local"])
        } catch {
            return try await list().map { VirtualMachineListItem(name: $0) }
        }
        guard let data = json.data(using: .utf8), !data.isEmpty,
              let rows = try? JSONDecoder().decode([TartListRow].self, from: data) else {
            return try await list().map { VirtualMachineListItem(name: $0) }
        }
        return rows.map(\.asListItem)
    }

    /// Capacity of the volume backing the Tart home directory (or the user's home volume when no
    /// `TART_HOME` override is configured). Returns `nil` if the volume can't be inspected.
    public func hostDiskUsage() -> TartDiskUsage? {
        let url = homeProvider.homeFolderUrl ?? FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]), let total = values.volumeTotalCapacity else {
            return nil
        }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        return TartDiskUsage(totalBytes: Int64(total), freeBytes: free)
    }

    public func getIPAddress(ofVirtualMachineNamed name: String, shouldUseArpResolver: Bool) async throws -> String {
        let arguments: [String]
        if shouldUseArpResolver {
            arguments = ["ip", "--resolver=arp", name]
        } else {
            arguments = ["ip", name]
        }
        let result = try await executeCommand(withArguments: arguments)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One row of `tart list --format json`. Keys are Tart's capitalised column names; numbers are
/// decoded leniently as `Double` since Tart reports whole-gigabyte integers.
private struct TartListRow: Decodable {
    let name: String
    let source: String?
    let state: String?
    let running: Bool?
    let size: Double?
    let disk: Double?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case source = "Source"
        case state = "State"
        case running = "Running"
        case size = "Size"
        case disk = "Disk"
    }

    var asListItem: VirtualMachineListItem {
        let isRunning: Bool?
        if let running {
            isRunning = running
        } else if let state {
            isRunning = state.lowercased() == "running"
        } else {
            isRunning = nil
        }
        return VirtualMachineListItem(
            name: name,
            source: source,
            state: state,
            running: isRunning,
            sizeGB: size,
            diskGB: disk
        )
    }
}

private extension Tart {
    @discardableResult
    private func executeCommand(withArguments arguments: [String]) async throws -> String {
        let locator = TartLocator(shell: shell)
        let filePath = try locator.locate()
        if let environment {
            return try await shell.runExecutable(
                atPath: filePath,
                withArguments: arguments,
                environment: environment
            )
        } else {
            return try await shell.runExecutable(
                atPath: filePath,
                withArguments: arguments
            )
        }
    }
}
