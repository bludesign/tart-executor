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
            logger: ConsoleLogger(subsystem: "RouterServer")
        )
    }

    public func run() async throws {
        try await server.run(port: environment.port)
    }
}
