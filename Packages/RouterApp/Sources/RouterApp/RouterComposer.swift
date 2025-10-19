import EnvironmentSettings
import Foundation
import LoggingData
import LoggingDomain
import TartCommon

public final class RouterComposer {
    private let environment: RouterEnvironment
    private let server: RouterServer

    public init(environment: RouterEnvironment) {
        self.environment = environment

        let hosts: [TartHost] = environment.hosts.map { tartHost in
                .init(
                    hostname: tartHost.hostname,
                    url: tartHost.url,
                    priority: tartHost.priority,
                    cpuLimit: tartHost.cpuLimit,
                    memoryLimit: tartHost.memoryLimit
                )
        }

        let labelsArray = environment.labels.components(separatedBy: ",").map { label in
            label.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        server = RouterServer(
            hosts: hosts,
            labels: .init(labelsArray),
            hostname: environment.hostname,
            logger: Self.logger(environment, subsystem: "RouterServer")
        )
    }

    public func run() async throws {
        try await server.run(port: environment.port)
    }
}

private extension RouterComposer {
    static func logger(_ environment: RouterEnvironment, subsystem: String) -> Logger {
        let consoleLogger = ConsoleLogger(subsystem: subsystem)

        guard let loggingEndpoint = environment.loggingEndpoint else {
            return consoleLogger
        }

        do {
            let endpointLogger = try EndpointLogger(
                subsystem: subsystem,
                hostname: environment.hostname,
                service: "tart-router",
                endpoint: loggingEndpoint
            )

            return MultiplexLogger(loggers: [consoleLogger, endpointLogger])
        } catch {
            print("Failed to create EndpointLogger: \(error.localizedDescription)")
            return consoleLogger
        }
    }
}
