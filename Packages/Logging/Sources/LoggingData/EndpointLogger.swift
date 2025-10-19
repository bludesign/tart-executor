import Foundation
import LoggingDomain

public final class EndpointLogger: LoggingDomain.Logger {
    private let subsystem: String
    private let hostname: String
    private let service: String
    private let endpointUrl: URL
    private let session: URLSession
    private let jsonEncoder: JSONEncoder
    private let dateFormatter = DateFormatter()

    public init(subsystem: String, hostname: String, service: String, endpoint: String) throws {
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        self.subsystem = subsystem
        self.hostname = hostname
        self.service = service
        self.endpointUrl = url

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5.0
        configuration.timeoutIntervalForResource = 10.0
        self.session = URLSession(configuration: configuration)
    
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        self.jsonEncoder = JSONEncoder()
    }

    public func info(_ message: String, parameters: [String: String]?) {
        sendLog(level: "info", message: message, parameters: parameters)
    }

    public func error(_ message: String, parameters: [String: String]?) {
        sendLog(level: "error", message: message, parameters: parameters)
    }
}

private extension EndpointLogger {
    struct LogEntry: Codable {
        let subsystem: String
        let level: String
        let message: String
        let host: String
        let service: String
        let timestamp: String
        let parameters: [String: String]?
    }

    func sendLog(level: String, message: String, parameters: [String: String]?) {
        let date = Date()
        let logEntry = LogEntry(
            subsystem: subsystem,
            level: level,
            message: message,
            host: hostname,
            service: service,
            timestamp: dateFormatter.string(from: date),
            parameters: parameters
        )

        Task {
            guard let jsonData = try? jsonEncoder.encode(logEntry) else {
                return
            }

            var request = URLRequest(url: endpointUrl)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Tart", forHTTPHeaderField: "User-Agent")
            request.httpBody = jsonData

            do {
                _ = try await session.data(for: request)
            } catch {
                print("Failed to send log to endpoint: \(error.localizedDescription)")
            }
        }
    }
}
