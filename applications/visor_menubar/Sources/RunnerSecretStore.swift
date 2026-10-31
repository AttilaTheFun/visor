import VisorRunner
import VisorServer

/// The Runner's secrets (its container servers' passwords and MCP tokens)
/// kept with the server's own: the keychain.
struct RunnerSecretStore: RunnerSecrets {
    let store: any SecretStore

    func value(_ name: String) -> String? { store.get(name) }

    func set(_ name: String, _ value: String?) { store.set(name, value) }
}
