import SwiftUI
import VisorClient
import VisorProtocol

/// What may be done with a session's agent where it is now: Stop and
/// Restart while it runs, Start once it is stopped, nothing while it
/// starts or stops. A server of 0.34 or before, which keeps no state,
/// offers Restart alone.
@MainActor
struct AgentStateButtons: View {
    var host: AgentServerConnection
    let session: SessionInfo

    var body: some View {
        switch session.agentState {
        case .running?:
            Button { host.stopAgent(session.id) } label: { Label("Stop Agent", systemImage: "stop.circle") }
            restart
        case .stopped?:
            Button { host.startAgent(session.id) } label: { Label("Start Agent", systemImage: "play.circle") }
        case .starting?, .stopping?:
            EmptyView()
        case nil:
            restart
        }
    }

    /// A new agent on the same conversation: for one that is stuck, or
    /// holds too much.
    private var restart: some View {
        Button { host.restartAgent(session.id) } label: { Label("Restart Agent", systemImage: "arrow.clockwise") }
    }

    /// The session's state in a word, for the inspector.
    static func stateTitle(_ session: SessionInfo) -> String {
        if session.archived { return "Archived" }
        switch session.agentState {
        case .starting?: return "Starting"
        case .stopping?: return "Stopping"
        case .stopped?: return "Stopped"
        case .running?, nil: return session.busy ? "Working" : "Idle"
        }
    }
}
