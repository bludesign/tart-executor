import Foundation
import Yams

// MARK: - Router

public struct RouterEnvironment: Decodable {
    public let hostname: String
    public let labels: String
    public let port: Int
    public let hosts: [TartHost]
    public let loggingEndpoint: String?
    public let apiToken: String?
    public let reconciliation: RouterReconciliationConfiguration?

    public init() throws {
        let configUrl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tart-router.yaml")
        let contents = try Data(contentsOf: configUrl)
        self = try YAMLDecoder().decode(Self.self, from: contents)
    }
}

/// The router periodically repairs missed GitHub webhooks using an executor's GitHub access.
public struct RouterReconciliationConfiguration: Decodable, Sendable {
    public let enabled: Bool
    public let intervalSeconds: TimeInterval
    /// Bearer token used for executor management APIs; independent of the router's API token.
    public let executorApiToken: String?

    public init(enabled: Bool = true, intervalSeconds: TimeInterval = 60, executorApiToken: String? = nil) {
        self.enabled = enabled
        self.intervalSeconds = max(1, intervalSeconds)
        self.executorApiToken = executorApiToken
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case intervalSeconds
        case executorApiToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            intervalSeconds: try container.decodeIfPresent(TimeInterval.self, forKey: .intervalSeconds) ?? 60,
            executorApiToken: try container.decodeIfPresent(String.self, forKey: .executorApiToken)
        )
    }
}

// MARK: - TartHost

public extension RouterEnvironment {
    struct TartHost: Decodable {
        public let hostname: String
        public let url: URL
        public let priority: Int
        public let cpuLimit: Int?
        public let memoryLimit: Int?
    }
}
