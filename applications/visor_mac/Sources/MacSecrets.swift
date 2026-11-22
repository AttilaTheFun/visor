// The server's keychain items (MacPlaces' server service), as every process
// of Visor.app's reads them: the app's and the server agent's (`Visor
// --server`, the same executable, so the same signature and entitlements).
// The app key (MacAppKey) is in the data-protection keychain under the
// app's own access group where the build has one (a Developer ID build,
// with its profile), so no other process of the user's can ask for it
// (NCH's review of visor#471); moved there from the login keychain the
// first time it's read. Without the group (a build signed ad hoc) it stays
// in the login keychain, as the log says. So is the admin token itself
// (0.65), which `Visor admin-token` prints (MacAdminTokenCommand). The
// other items stay there for now.

import Foundation
import VisorServer
import VisorServerApple

enum MacSecrets {
    /// The items kept in the data-protection keychain when the build can:
    /// the app key, and the admin token itself (`Visor admin-token`).
    static let protectedNames: Set<String> = [MacAppKey.name, VisorServer.adminTokenSecret]

    /// The server's secrets, the app key protected where it can be.
    static func make() -> any SecretStore {
        let service = MacPlaces.serverService
        let (store, why) = KeychainSecrets.dataProtection(service: service, bundleID: MacPlaces.own)
        // Read once the platform is given: the first lookup comes after.
        return ProtectedSecrets(legacy: KeychainSecrets(service: service), protected: store, names: protectedNames,
                                unprotected: why, log: { ServerPlatform.current.log("secrets: " + $0) })
    }
}
