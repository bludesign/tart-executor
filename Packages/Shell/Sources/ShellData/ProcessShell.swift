import Foundation
import ShellDomain

public struct ProcessShell: Shell {
    public init() {}

    public func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        let process = Process()
        let sendableProcess = SendableProcess(process)
        return try await withTaskCancellationHandler {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.arguments = arguments
            process.launchPath = executablePath
            process.standardInput = nil
            process.environment = environment
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // Explicitly close the pipe file handle to prevent running out of file descriptors.
            // See https://github.com/swiftlang/swift/issues/57827
            try pipe.fileHandleForReading.close()
            process.waitUntilExit()
            let result = String(data: data, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw ProcessShellError.unexpectedTerminationStatus(
                    process.terminationStatus,
                    executablePath: executablePath,
                    arguments: arguments,
                    environment: environment,
                    result: result
                )
            }
            return result
        } onCancel: {
            if sendableProcess.process.isRunning {
                sendableProcess.process.terminate()
            }
        }
    }
}
