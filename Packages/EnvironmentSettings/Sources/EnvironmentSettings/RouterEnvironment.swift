import Foundation
import Yams

// MARK: - Router

public struct RouterEnvironment: Decodable {
    public let hostname: String
    public let labels: String
    public let port: Int
    public let hosts: [TartHost]
    public let loggingEndpoint: String?

    public init() throws {
        let configUrl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tart-router.yaml")
        let contents = try Data(contentsOf: configUrl)
        self = try YAMLDecoder().decode(Self.self, from: contents)
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
