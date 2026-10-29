import Foundation

public struct WorkflowJob: Codable, Identifiable, Hashable {
    public let id: Int
    public let action: WorkflowAction
    public let labels: Set<String>
    public let github: GitHubJobContext?

    public var filteredLabels: Set<String> {
        labels.filter { label in
            !(label.starts(with: "memory:") || label.starts(with: "minMemory:") || label.starts(with: "cpu:") || label.starts(with: "minCpu:"))
        }
    }

    public var cpu: Int? {
        intValue(forLabel: "cpu")
    }

    public var minimumCpu: Int? {
        intValue(forLabel: "minCpu")
    }

    public var memory: Int? {
        intValue(forLabel: "memory")
    }

    public var minimumMemory: Int? {
        intValue(forLabel: "minMemory")
    }

    public init(id: Int, action: WorkflowAction, labels: Set<String>, github: GitHubJobContext? = nil) {
        self.id = id
        self.action = action
        self.labels = labels
        self.github = github
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private func intValue(forLabel label: String) -> Int? {
        guard let memoryArray = labels.first(where: { $0.starts(with: "\(label):") })?.components(separatedBy: ":"), memoryArray.count == 2 else {
            return nil
        }
        return memoryArray.last.flatMap { Int($0) }
    }
}

public enum WorkflowAction: String, Sendable {
    case routerStart = "router_start"
    case waiting
    case queued
    case inProgress = "in_progress"
    case completed
    case unknown
}

extension WorkflowAction: Codable {
    public init(from decoder: Decoder) throws {
        self = try WorkflowAction(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct WebhookResponse: Codable {
    public struct RepositoryResponse: Codable {
        public let full_name: String

        public init(fullName: String) {
            full_name = fullName
        }
    }

    public struct WorkflowJobResponse: Codable, Identifiable {
        public let id: Int
        public let labels: Set<String>
        public var run_id: Int?
        public var run_attempt: Int?
        public var name: String?
        public var workflow_name: String?
        public var html_url: String?
        public var head_branch: String?
        public var head_sha: String?
        public var status: String?
        public var conclusion: String?
        public var runner_name: String?
        public var created_at: String?
        public var started_at: String?
        public var completed_at: String?
        /// Used by manual dispatch and recovery to preserve normalized enrichment.
        public var github: GitHubJobContext?

        public init(id: Int, labels: Set<String>) {
            self.id = id
            self.labels = labels
        }
    }

    public let action: WorkflowAction
    public let workflow_job: WorkflowJobResponse
    public let repository: RepositoryResponse?

    public var jobContext: GitHubJobContext {
        func date(_ value: String?) -> Date? {
            guard let value else { return nil }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: value)
        }
        let job = workflow_job
        let context = GitHubJobContext(
            workflowJobId: String(job.id), workflowRunId: job.run_id.map(String.init),
            repository: repository?.full_name, name: job.name, workflowName: job.workflow_name,
            htmlUrl: job.html_url, runAttempt: job.run_attempt, headBranch: job.head_branch,
            headSha: job.head_sha, status: job.status ?? action.rawValue, conclusion: job.conclusion,
            runnerName: job.runner_name, createdAt: date(job.created_at), startedAt: date(job.started_at),
            completedAt: date(job.completed_at), observedAt: Date(), source: "webhook"
        )
        return job.github.map { $0.merging(context) } ?? context
    }

    public init(action: WorkflowAction, workflow_job: WorkflowJobResponse, repository: RepositoryResponse? = nil) {
        self.action = action
        self.workflow_job = workflow_job
        self.repository = repository
    }
}
