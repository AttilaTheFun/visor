// The client's settings on the Mac: UserDefaults as before
// (NativeVisorSettingsService), and its secrets (its computers' passwords,
// `password.<server id>`; its SSH key, `ssh.key`; and what it keeps with
// them: the computers, their host keys, its own id) under the client's
// keychain service, `com.LoganShire.Visor`, in the data-protection keychain
// under Visor's group (`<team>.com.LoganShire.Visor`) where the build has
// it. Visor's sandboxed release can't read the login keychain's items, so
// 0.66, still unsandboxed, moves them (docs/DEVELOPMENT.md, "Sandboxed
// Visor"): all at the app's start, and any left the first time it's read,
// as the server's app key moves (ProtectedSecrets, #502: the login
// keychain's copy deleted first, then written to the group and read back,
// put back where it was if it doesn't read back). Reads ask the group
// first. A build without the group (signed ad hoc) keeps them in the login
// keychain, as the log says.

import Foundation
import VisorServer
import VisorServerApple
import VisorServices

@MainActor
final class MacClientSettings: VisorSettingsService {
    private let settings: NativeVisorSettingsService
    private let secrets: ProtectedSecrets

    /// `moving`: every item the login keychain holds moved now (not in a
    /// fixture's launch, whose secrets are the fixture's).
    init(moving: Bool) {
        let service = MacPlaces.clientService
        settings = NativeVisorSettingsService(keychainService: service)
        let legacy = KeychainSecrets(service: service)
        // Kept with a backup, as the login keychain's were: a Mac restored
        // from one still knows its computers.
        let (store, why) = KeychainSecrets.dataProtection(service: service, bundleID: MacPlaces.own, thisDeviceOnly: false)
        secrets = ProtectedSecrets(legacy: legacy, protected: store, protecting: { _ in true }, unprotected: why,
                                   log: { NSLog("Visor: client secrets: %@", $0) })
        if moving, store != nil { secrets.moveAll(legacy.accounts()) }
    }

    func get(key: String) -> String { settings.get(key: key) }

    func set(key: String, value: String) { settings.set(key: key, value: value) }

    func secret(key: String) -> String { secrets.get(key) ?? "" }

    func setSecret(key: String, value: String) { secrets.set(key, value.isEmpty ? nil : value) }
}
