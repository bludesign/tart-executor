import Foundation

/// Bearer-token authorization for the management API.
///
/// When no token is configured the API is open, matching the services' existing private-network
/// trust model. When a token is set, every `/api/*` request must present
/// `Authorization: Bearer <token>`.
public enum APIAuth {
    /// Returns `true` when the request should be allowed given the optionally-configured token.
    public static func isAuthorized(authorizationHeader: String?, token: String?) -> Bool {
        guard let token, !token.isEmpty else {
            // No token configured: the API is open.
            return true
        }
        guard let authorizationHeader else {
            return false
        }
        return constantTimeEquals(authorizationHeader, "Bearer \(token)")
    }

    /// Length-checked constant-time comparison to avoid leaking the token via response timing.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }
}
