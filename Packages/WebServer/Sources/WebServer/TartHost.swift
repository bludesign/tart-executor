import Foundation

public final class TartHost {
    let hostname: String
    let url: URL
    let priority: Int
    let cpuLimit: Int?
    let memoryLimit: Int?
    var lastStatus: TartHostStatus?

    public init(hostname: String, url: URL, priority: Int, cpuLimit: Int?, memoryLimit: Int?) {
        self.hostname = hostname
        self.url = url
        self.priority = priority
        self.cpuLimit = cpuLimit
        self.memoryLimit = memoryLimit
    }
}
