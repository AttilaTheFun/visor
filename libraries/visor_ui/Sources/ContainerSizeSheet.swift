import SwiftUI
import VisorClient
import VisorProtocol

/// Moves a session into a container of the size chosen, or makes the one
/// it is in again at another size: its agent is started again there, with
/// the same folder and conversation (and, for a resize, the same disk).
@MainActor
struct ContainerSizeSheet: View {
    var host: AgentServerConnection
    let session: SessionInfo
    let close: () -> Void
    @State private var size: ContainerSize

    init(host: AgentServerConnection, session: SessionInfo, close: @escaping () -> Void) {
        self.host = host
        self.session = session
        self.close = close
        _size = State(initialValue: session.container?.size ?? .standard)
    }

    private var resizing: Bool { session.container != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ContainerSizeRows(size: $size)
                } footer: {
                    Text(resizing
                         ? "The container is made again at this size and its agent started again in it: the same folder, conversation and disk (a disk of another size starts empty). \(ContainerSizeRows.heavyNote)"
                         : "The agent runs in a Linux container on the computer, which sees the project's folder and Xcode, and nothing else of it. \(ContainerSizeRows.heavyNote)")
                }
            }
            .navigationTitle(resizing ? "Container Size" : "Move into a Container")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(resizing ? "Resize" : "Move") {
                        host.contain(session.id, into: true, size: size)
                        close()
                    }
                    .disabled(session.busy || (resizing && session.container?.size == size))
                    .accessibilityIdentifier("container-size-done")
                }
            }
        }
    }
}
