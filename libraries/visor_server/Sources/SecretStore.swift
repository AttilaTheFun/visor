// What the server keeps secret — its password, the APNs key — where the
// system keeps secrets: the keychain on a Mac, a file only its user can
// read elsewhere. Tests use a store of their own.

/// Secrets by name.
public protocol SecretStore: AnyObject, Sendable {
    func get(_ key: String) -> String?
    /// Sets a secret; nil or empty removes it.
    func set(_ key: String, _ value: String?)
}
