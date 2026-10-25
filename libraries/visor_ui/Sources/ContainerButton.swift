import SwiftUI
import VisorClient
import VisorProtocol

/// Moves a session's agent into a Linux container on its computer (of a
/// size chosen in `sizing`'s sheet), resizes the one it is in, or moves it
/// out onto the computer itself: the same folder and conversation, the
/// agent started again on the other side. Not while it works.
@MainActor
struct ContainerButton: View {
    var host: AgentServerConnection
    let session: SessionInfo
    /// Opens the size sheet (ContainerSizeSheet) for this session.
    let sizing: () -> Void

    var body: some View {
        if session.container != nil {
            Button(action: sizing) { Label("Container Size…", systemImage: "slider.horizontal.3") }
                .disabled(session.busy)
            Button { host.contain(session.id, into: false) } label: { Label("Run on the Computer", systemImage: "desktopcomputer") }
                .disabled(session.busy)
        } else if host.containersAvailable {
            Button(action: sizing) { Label("Move into a Container…", systemImage: "shippingbox") }
                .disabled(session.busy)
        }
    }
}
