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
}
