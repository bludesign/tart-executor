import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol NetworkingService {
    func data(from request: URLRequest) async -> NetworkResponse<Data>
    func load<T: Decodable>(
        _ valueType: T.Type,
        from request: URLRequest
    ) async -> NetworkResponse<T>
}
