/// Small persistent settings (UserDefaults on Apple, localStorage on the
/// web): `get` returns "" for an unset key. Secrets (a computer's password)
/// go through `secret`/`setSecret`: the keychain on Apple; a host with no
/// keychain keeps them with the rest.
@MainActor
public protocol VisorSettingsService {
    func get(key: String) -> String
    func set(key: String, value: String)
    func secret(key: String) -> String
    func setSecret(key: String, value: String)
}

public extension VisorSettingsService {
    func secret(key: String) -> String { get(key: "secret." + key) }
    func setSecret(key: String, value: String) { set(key: "secret." + key, value: value) }

    /// A setting kept with the secrets: what the device must not lose and
    /// others should not read — the computers it knows, the SSH host keys
    /// it trusts, its own id. On Apple that is the keychain, which keeps
    /// it when the app is deleted and installed again (and in an
    /// encrypted backup). Read from the plain settings where an earlier
    /// build kept it (or where it went when the keychain would not take
    /// it), and moved — the plain copy cleared only once the keychain
    /// reads it back, so a keychain that refuses (locked, asking) loses
    /// nothing.
    func kept(key: String) -> String {
        let value = secret(key: key)
        if !value.isEmpty { return value }
        let earlier = get(key: key)
        guard !earlier.isEmpty else { return "" }
        setSecret(key: key, value: earlier)
        if secret(key: key) == earlier { set(key: key, value: "") }
        return earlier
    }

    /// Keeps a setting with the secrets; in the plain settings instead
    /// when the keychain does not take it, so it is never lost.
    func setKept(key: String, value: String) {
        setSecret(key: key, value: value)
        if secret(key: key) == value {
            if !get(key: key).isEmpty { set(key: key, value: "") }
        } else {
            set(key: key, value: value)
        }
    }
}
