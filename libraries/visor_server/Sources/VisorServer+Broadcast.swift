// Telling the clients: one session's subscribers, or everyone.

import AppKit
import ClaudeTranscript
import MessageCache
import Foundation
import Network
import VisorProtocol

extension VisorServer {
    func broadcast(_ envelope: Envelope, session: SessionRecord) {
        for key in session.subscribers {
            connections[key]?.send(envelope)
        }
    }

    /// Nothing to say is nothing sent.
    func broadcast(_ envelope: Envelope?, session: SessionRecord) {
        if let envelope { broadcast(envelope, session: session) }
    }

    func broadcastSessions() {
        let envelope = Envelope.sessions(sessions.map(\.info))
        for connection in connections.values where connection.authenticated { connection.send(envelope) }
        notifyPushes()
    }

    /// What agents are on offer, after that changed (a key was entered).
    func broadcastCatalogs() {
        let envelope = Envelope.catalogs(catalogs())
        for connection in connections.values where connection.authenticated { connection.send(envelope) }
    }

    func broadcastSessionsSoon() {
        guard !sessionsBroadcastPending else { return }
        sessionsBroadcastPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            self.sessionsBroadcastPending = false
            self.broadcastSessions()
        }
    }
}
