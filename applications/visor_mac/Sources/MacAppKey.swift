// The key Visor.app shows at its own server's socket file
// (VisorServer.appKey, `X-Visor-App-Key`): kept with the server's keychain
// items (MacPlaces' server service), in the data-protection keychain under
// Visor.app's own access group (MacSecrets), so another process of this
// user's, an agent's, is told there's none and can't show it. What every
// process of the app's does with it is AppKeyKeeper's (the server library,
// tested on Linux): the server takes the one kept at its start, in the
// app's process or the server agent's, and makes one only when there is
// none; the app reads the kept one for each call it makes there
// (VisorSocketFile's services), never a copy of its own from earlier; and
// a call that didn't show the server's key has the server ask the keychain
// again (VisorServer.appKeyAskedAgain).

import Foundation
import VisorServer

enum MacAppKey {
    static let header = "X-Visor-App-Key"
    static let name = AppKeyKeeper.name

    private static let keeper = AppKeyKeeper(secrets: { ServerPlatform.current.secrets },
                                             log: { ServerPlatform.current.log($0) })

    /// The server's key at its start: the one kept, else one made and kept.
    static func made() -> String { keeper.serverKey() }

    /// The server's key asked again after a call that didn't show it.
    static func reconciled(_ current: String?) -> String? { keeper.reconciled(current) }

    /// The key a call at the socket file shows; nil until the server has
    /// made one.
    static var current: String? { keeper.shown }

    /// The header every call at the socket file carries.
    static var headers: [String: String] { current.map { [header: $0] } ?? [:] }
}
