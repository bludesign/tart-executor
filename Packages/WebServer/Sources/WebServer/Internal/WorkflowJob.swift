import Foundation

public struct WorkflowJob: Codable, Identifiable, Hashable {
    public let id: Int
    public let action: WorkflowAction
    public let labels: Set<String>

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

public enum WorkflowAction: String {
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

struct WebhookResponse: Codable {
    struct WorkflowJobResponse: Codable, Identifiable {
        let id: Int
        let labels: Set<String>
    }

    let action: WorkflowAction
    let workflow_job: WorkflowJobResponse
}
