import Foundation

/// Fresh GitHub state for a single job. Lookup errors are returned as HTTP errors instead.
public struct GitHubJobStatusDTO: Codable, Sendable {
    public let id: Int
    public let repository: String
    public let status: String
    public let labels: [String]
    public let runnerName: String?

    public init(id: Int, repository: String, status: String, labels: [String], runnerName: String?) {
        self.id = id
        self.repository = repository
        self.status = status
        self.labels = labels
        self.runnerName = runnerName
    }
}
