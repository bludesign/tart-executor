import FlyingFox
import Foundation

public extension HTTPResponse {
    /// Builds a JSON `HTTPResponse` by encoding `value`. Falls back to a 500 error body if
    /// encoding fails.
    static func json(_ value: some Encodable, statusCode: HTTPStatusCode = .ok, encoder: JSONEncoder) -> HTTPResponse {
        do {
            let data = try encoder.encode(value)
            return HTTPResponse(statusCode: statusCode, headers: [.contentType: "application/json"], body: data)
        } catch {
            return .jsonError("Failed to encode response", statusCode: .init(500, phrase: "Internal Server Error"))
        }
    }

    /// Builds a JSON error response of the form `{ "error": "..." }`.
    static func jsonError(_ message: String, statusCode: HTTPStatusCode) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(ErrorResponse(error: message))) ?? Data(#"{"error":"error"}"#.utf8)
        return HTTPResponse(statusCode: statusCode, headers: [.contentType: "application/json"], body: data)
    }
}
