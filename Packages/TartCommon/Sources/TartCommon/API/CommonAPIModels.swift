import Foundation

/// Standard error body returned by the management API.
public struct ErrorResponse: Codable {
    public let error: String

    public init(error: String) {
        self.error = error
    }
}

/// Response for `GET /api/v1/health`.
public struct HealthResponse: Codable {
    public let status: String
    public let service: String
    public let version: String
    public let startedAt: Date
    public let uptimeSeconds: Double

    public init(status: String = "ok", service: String, version: String, startedAt: Date, uptimeSeconds: Double) {
        self.status = status
        self.service = service
        self.version = version
        self.startedAt = startedAt
        self.uptimeSeconds = uptimeSeconds
    }
}

/// Request body for cancelling jobs by their label set. Shared by the executor `POST /cancel`
/// endpoint (router → executor) and the management API cancel endpoints.
public struct CancelJobsRequest: Codable {
    public let labels: Set<String>

    public init(labels: Set<String>) {
        self.labels = labels
    }
}

/// Response for the management API cancel endpoints.
public struct CancelResponse: Codable {
    public let cancelled: Bool
    public let cancelledCount: Int?

    public init(cancelled: Bool, cancelledCount: Int? = nil) {
        self.cancelled = cancelled
        self.cancelledCount = cancelledCount
    }
}
