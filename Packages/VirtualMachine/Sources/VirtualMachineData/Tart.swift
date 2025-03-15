import ShellDomain

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
