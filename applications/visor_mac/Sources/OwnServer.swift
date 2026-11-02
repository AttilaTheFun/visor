// This Mac's server in Visor's window, without pairing: the server in the
// app's own process, added to the client's computers as its connection code
// would add it, but at this Mac's loopback address, which needs no network
// path to be open. Once added it is a computer like any other here: a new
// password is taken in, and one forgotten by hand stays forgotten.

import Foundation
import Observation
import VisorClient
import VisorProtocol
import VisorServer

@MainActor
enum OwnServer {
    /// Set once this Mac's server has been added: from then on only the one
    /// held is kept up to date, so forgetting it sticks.
    private static let addedKey = "visor.ownServerAdded"

    /// The connection code a client on this Mac takes: loopback first, the
    /// server's other paths after it. Nil until a password is set.
    static func code(of server: VisorServer) -> ConnectionCode? {
        guard !server.password.isEmpty else { return nil }
        let loopback = "\(server.servesTLS ? "https" : "http")://127.0.0.1:\(server.port)"
        return ConnectionCode(name: server.hostName, host: loopback, password: server.password, id: server.id,
                              paths: server.ownAddresses.filter { $0 != loopback }, auth: server.settings.authentication)
    }

    /// The computer held here that is this Mac's server, by its id.
    static func held(_ server: VisorServer, in store: VisorStore) -> AgentServerConnection? {
        guard !server.id.isEmpty else { return nil }
        return store.servers.first { $0.record.serverID == server.id }
    }

    /// Adds the server to the store the first time it has a password, and
    /// keeps the one held signing in with the password it has now.
    static func follow(_ server: VisorServer, in store: VisorStore) {
        join(server, store)
        withObservationTracking { _ = server.password } onChange: {
            Task { @MainActor in follow(server, in: store) }
        }
    }

    /// Adds it, whether or not it was before: the welcome page's button.
    static func add(_ server: VisorServer, to store: VisorStore) {
        guard let code = code(of: server) else { return }
        UserDefaults.standard.set(true, forKey: addedKey)
        store.open(code.encoded)
    }

    private static func join(_ server: VisorServer, _ store: VisorStore) {
        guard let code = code(of: server) else { return }
        if let held = held(server, in: store) {
            // Signing in as it is: left alone, not connected again.
            if held.record.secret != code.password { store.open(code.encoded) }
        } else if !UserDefaults.standard.bool(forKey: addedKey) {
            add(server, to: store)
        }
    }
}
