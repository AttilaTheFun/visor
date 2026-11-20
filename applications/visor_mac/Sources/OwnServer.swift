// This Mac's server in Visor's window, without pairing: the server agent,
// or the server in the app's own process (LocalServer), added to the
// client's computers at its socket file (`~/.visor/server.sock`,
// SocketFileURL), as an SSH client reaches it: as this user, no password,
// no network path. Once added it is a computer like any other here, and
// one forgotten by hand stays forgotten. The server agent is the same
// server as the one in the app (its id, its socket file), so a Mac that
// had it in the app keeps the same computer when the agent takes over; a
// computer held from before at this Mac's loopback, with the password, is
// moved to the socket file.

import Foundation
import VisorClient
import VisorProtocol
import VisorServer

@MainActor
enum OwnServer {
    /// Set once this Mac's server has been added: from then on only the one
    /// held is kept up to date, so forgetting it sticks.
    private static let addedKey = "visor.ownServerAdded"

    /// Where the app reaches this Mac's server: its socket file.
    static var address: String { SocketFileURL.address(socket: VisorServer.socketPath) }

    /// This Mac's server as a computer of the client's: at its socket file,
    /// signed in to by nothing (the socket file lets this user in).
    static func record(name: String, id: String = "") -> AgentServerRecord {
        AgentServerRecord(name: name, address: address, serverID: id, authentication: NoAuthenticator.name)
    }

    /// The computer held here that is this Mac's server, by its id.
    static func held(id: String, in store: VisorStore) -> AgentServerConnection? {
        guard !id.isEmpty else { return nil }
        return store.servers.first { $0.record.serverID == id }
    }

    /// Kept up to date as the server says how it stands: added the first
    /// time it has a password (unless it was forgotten here since), and a
    /// computer held for it elsewhere than its socket file moved there.
    static func join(_ controls: ServerControls, in store: VisorStore) {
        guard !controls.id.isEmpty else { return }
        if let held = held(id: controls.id, in: store) {
            if held.record.address != address { store.add(record(name: controls.host, id: controls.id)) }
        } else if !UserDefaults.standard.bool(forKey: addedKey) {
            add(controls, to: store)
        }
    }

    /// Adds it, whether or not it was before: the welcome page's button.
    static func add(_ controls: ServerControls, to store: VisorStore) {
        UserDefaults.standard.set(true, forKey: addedKey)
        store.addingServer = false
        store.add(record(name: controls.host, id: controls.id))
    }
}
