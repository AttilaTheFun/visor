import SwiftUI
import VisorClient
import VisorProtocol

/// Moves a session's agent into a Linux container on its computer, or out
/// of it onto the computer itself: the same folder and conversation, the
/// agent started again on the other side. Not while it works.
@MainActor
struct ContainerButton: View {
    var host: AgentServerConnection
    let session: SessionInfo

    var body: some View {
        if session.container != nil {
            Button { host.contain(session.id, into: false) } label: { Label("Run on the Computer", systemImage: "desktopcomputer") }
                .disabled(session.busy)
        } else if host.containersAvailable {
            Button { host.contain(session.id, into: true) } label: { Label("Move into a Container", systemImage: "shippingbox") }
                .disabled(session.busy)
        }
    }
}
