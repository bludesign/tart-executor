import Foundation
import LoggingDomain

public final class MultiplexLogger: LoggingDomain.Logger {
    private let loggers: [Logger]

    public init(loggers: [Logger]) {
        self.loggers = loggers
    }

    public func info(_ message: String) {
        loggers.forEach { $0.info(message) }
    }

    public func error(_ message: String) {
        loggers.forEach { $0.error(message) }
    }
}
