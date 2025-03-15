import Foundation

public protocol GitHubCredentialsStore: AnyObject {
    var organizationName: String? { get }
    var repositoryName: String? { get }
    var ownerName: String? { get }
    var appId: String? { get }
    var privateKey: Data? { get }
}
