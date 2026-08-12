import Foundation

/// Bounds on the GitHub Actions scan. GitHub has no org-wide endpoint for workflow runs or jobs,
/// so a scan costs roughly one request per repository plus one per unfinished run. Every knob
/// here exists to keep that bounded and inside the installation's hourly rate limit.
public struct GitHubScanConfiguration: Sendable {
    public let isEnabled: Bool
    /// How long a snapshot is served without triggering a refresh.
    public let cacheSeconds: TimeInterval
    /// How long the repository list is reused before being re-fetched.
    public let repositoryCacheSeconds: TimeInterval
    /// Upper bound on repositories visited in one scan.
    public let maxRepositories: Int
    /// Requests in flight at once. Unbounded fan-out trips GitHub's secondary rate limits.
    public let maxConcurrentRequests: Int
    /// Workflow runs fetched per repository, newest first.
    public let runsPerRepository: Int
    /// Wall-clock budget for one scan.
    public let timeoutSeconds: TimeInterval
    /// Abort the scan when the installation's remaining request budget falls below this.
    public let rateLimitFloor: Int
    /// When non-empty, only these `owner/repo` names are scanned.
    public let includeRepositories: [String]
    /// `owner/repo` names never scanned.
    public let excludeRepositories: [String]

    public static let `default` = Self()

    public init(
        isEnabled: Bool = true,
        cacheSeconds: TimeInterval = 30,
        repositoryCacheSeconds: TimeInterval = 600,
        maxRepositories: Int = 200,
        maxConcurrentRequests: Int = 4,
        runsPerRepository: Int = 50,
        timeoutSeconds: TimeInterval = 20,
        rateLimitFloor: Int = 200,
        includeRepositories: [String] = [],
        excludeRepositories: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.cacheSeconds = max(0, cacheSeconds)
        self.repositoryCacheSeconds = max(0, repositoryCacheSeconds)
        self.maxRepositories = max(1, maxRepositories)
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.runsPerRepository = min(100, max(1, runsPerRepository))
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.rateLimitFloor = max(0, rateLimitFloor)
        self.includeRepositories = includeRepositories
        self.excludeRepositories = excludeRepositories
    }
}
