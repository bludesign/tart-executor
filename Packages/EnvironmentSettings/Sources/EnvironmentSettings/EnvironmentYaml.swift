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
    let apiToken: String?
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
        let scan: Scan?
    }
}

// MARK: - Github Scan

extension EnvironmentYaml.Github {
    /// Bounds on the GitHub Actions queue scan. Every field is optional so existing config files
    /// keep working; omitting the whole block leaves scanning on with the defaults.
    struct Scan: Decodable {
        let enabled: Bool?
        let cacheSeconds: Int?
        let repositoryCacheSeconds: Int?
        let maxRepositories: Int?
        let maxConcurrentRequests: Int?
        let runsPerRepository: Int?
        let timeoutSeconds: Int?
        let rateLimitFloor: Int?
        let includeRepositories: [String]?
        let excludeRepositories: [String]?

        var configuration: GitHubScanConfiguration {
            let defaults = GitHubScanConfiguration.default
            return GitHubScanConfiguration(
                isEnabled: enabled ?? defaults.isEnabled,
                cacheSeconds: cacheSeconds.map(TimeInterval.init) ?? defaults.cacheSeconds,
                repositoryCacheSeconds: repositoryCacheSeconds.map(TimeInterval.init) ?? defaults.repositoryCacheSeconds,
                maxRepositories: maxRepositories ?? defaults.maxRepositories,
                maxConcurrentRequests: maxConcurrentRequests ?? defaults.maxConcurrentRequests,
                runsPerRepository: runsPerRepository ?? defaults.runsPerRepository,
                timeoutSeconds: timeoutSeconds.map(TimeInterval.init) ?? defaults.timeoutSeconds,
                rateLimitFloor: rateLimitFloor ?? defaults.rateLimitFloor,
                includeRepositories: includeRepositories ?? defaults.includeRepositories,
                excludeRepositories: excludeRepositories ?? defaults.excludeRepositories
            )
        }
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
