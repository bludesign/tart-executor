import Foundation
import LoggingData
import LoggingDomain
import Router
import WebServer

let environment = try RouterEnvironment()

let hosts: [TartHost] = environment.hosts.map { tartHost in
    .init(hostname: tartHost.hostname, url: tartHost.url, priority: tartHost.priority, cpuLimit: tartHost.cpuLimit, memoryLimit: tartHost.memoryLimit)
}

let labelsArray = environment.labels.components(separatedBy: ",").map { label in
    label.trimmingCharacters(in: .whitespacesAndNewlines)
}

let server = RouterServer(
    hosts: hosts,
    labels: .init(labelsArray),
    hostname: environment.hostname,
    logger: ConsoleLogger(subsystem: "RouterServer")
)

Task {
    try await server.run(port: environment.port)
}

RunLoop.main.run()
