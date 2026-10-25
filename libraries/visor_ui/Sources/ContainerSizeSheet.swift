import SwiftUI
import VisorClient
import VisorProtocol

/// Moves a session into a container given the size chosen (6 cores, 16 GB
/// and 128 GB to start with): its agent is started again there, with the
/// same folder and conversation.
@MainActor
struct ContainerSizeSheet: View {
    var host: AgentServerConnection
    let session: SessionInfo
    let close: () -> Void
    @State private var size = ContainerSize.standard

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ContainerSizeRows(size: $size)
                } footer: {
                    Text("The agent runs in a Linux container on the computer, which sees the project's folder and Xcode, and nothing else of it. \(ContainerSizeRows.heavyNote)")
                }
            }
            .navigationTitle("Move into a Container")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        host.contain(session.id, into: true, size: size)
                        close()
                    }
                    .disabled(session.busy)
                    .accessibilityIdentifier("container-size-done")
                }
            }
        }
    }
}
