import Foundation
import GitHubDomain

// MARK: - EnvironmentYaml

struct EnvironmentYaml: Decodable {
    let tart: Tart
    let github: Github
    let runner: Runner
    let webhook: Webhook
    let hostname: String
    let cpuLimit: Int
    let totalMemory: Int
    let loggingEndpoint: String?
}

// MARK: - Tark

extension EnvironmentYaml {
    struct Tart: Decodable {
        let homeFolder: String?
        let netBridgedAdapter: String?
        let isHeadless: Bool?
        let isInsecure: Bool?
        let insecureDomains: [String]?
        let numberOfVirtualMachines: Int?
        let ssh: SSH?
        let defaultMemory: Int?
        let defaultCpu: Int?
    }
}

// MARK: - SSH

extension EnvironmentYaml.Tart {
    struct SSH: Decodable {
        let username: String
        let password: String
    }
}

// MARK: - Github

extension EnvironmentYaml {
    struct Github: Decodable {
        let runnerScope: GitHubRunnerScope
        let organizationName: String?
        let ownerName: String?
        let repositoryName: String?
        let appId: String
        let privateKey: String
    }
}

// MARK: - Runner

extension EnvironmentYaml {
    struct Runner: Decodable {
        let labels: String
        let group: String?
        let disableUpdates: Bool?
    }
}

// MARK: - Webhook

extension EnvironmentYaml {
    struct Webhook: Decodable {
        let port: Int
        let routerUrl: String?
        let localUrl: String?
    }
}
