import Foundation
import LoggingDomain

public final class ConsoleLogger: LoggingDomain.Logger {
    private let subsystem: String
    private let dateFormatter: DateFormatter

    public init(subsystem: String) {
        self.subsystem = subsystem
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "MMM dd HH:mm:ss"
    }

    public func info(_ message: String, parameters: [String: String]?) {
        let timestamp = dateFormatter.string(from: Date())
        let parametersString = formatParameters(parameters)
        print("\(timestamp) INFO \(subsystem): \(message)\(parametersString)")
    }

    public func error(_ message: String, parameters: [String: String]?) {
        let timestamp = dateFormatter.string(from: Date())
        let parametersString = formatParameters(parameters)
        print("\(timestamp) ERROR \(subsystem): \(message)\(parametersString)")
    }
}

private extension ConsoleLogger {
    func formatParameters(_ parameters: [String: String]?) -> String {
        guard let parameters = parameters, !parameters.isEmpty else {
            return ""
        }
        let paramString = parameters.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        return " [\(paramString)]"
    }
}
