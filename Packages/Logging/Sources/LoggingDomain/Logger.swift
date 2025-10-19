public protocol Logger {
    func info(_ message: String, parameters: [String: String]?)
    func error(_ message: String, parameters: [String: String]?)
}

public extension Logger {
    func info(_ message: String) {
        info(message, parameters: nil)
    }

    func error(_ message: String) {
        error(message, parameters: nil)
    }
}
