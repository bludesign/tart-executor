import Foundation

public final class TartHost {
    public let hostname: String
    public let url: URL
    public let priority: Int
    public let cpuLimit: Int?
    public let memoryLimit: Int?
    public var lastStatus: TartHostStatus?

    public init(hostname: String, url: URL, priority: Int, cpuLimit: Int?, memoryLimit: Int?) {
        self.hostname = hostname
        self.url = url
        self.priority = priority
        self.cpuLimit = cpuLimit
        self.memoryLimit = memoryLimit
    }
}
