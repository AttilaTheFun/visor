// What Uninstall… reads of the keychain to make its plan: the Mac's
// (Security, in Visor Disk Utility), or a test's.

public protocol UninstallKeychain: Sendable {
    /// The accounts of the generic passwords of `service`: in the login
    /// keychain when `accessGroup` is nil, else in the data-protection
    /// keychain under that group.
    func accounts(service: String, accessGroup: String?) -> [String]
}
