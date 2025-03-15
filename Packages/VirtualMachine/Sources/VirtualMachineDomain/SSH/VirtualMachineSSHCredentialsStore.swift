public protocol VirtualMachineSSHCredentialsStore: AnyObject {
    var username: String? { get }
    var password: String? { get }
}
