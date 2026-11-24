// A session given another working directory, from its inspector: a folder
// on its computer, one that exists there, typed or pasted. The computer
// ends its agent, moves its conversation to the new folder's keeping and
// resumes it there (`POST /api/sessions/<id>/folder`); what it refused the
// move for (a turn still going, say) is said here, and the sheet stays.

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct WorkingDirectorySheet: View {
    var host: AgentServerConnection
    let session: SessionInfo
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    /// Asked for, and not answered yet.
    @State private var moving = false
    /// Why the computer refused it, in its words.
    @State private var refused: String?

    private var computer: String { host.record.name.isEmpty ? host.record.address : host.record.name }
    private var wanted: String { path.trimmed }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Now", value: session.cwd)
                    TextField("A folder on \(computer)", text: $path)
                        .autocorrectionDisabled()
                        // Typed as it is: no capitals put in for the user.
                        .keyboardTypeURL()
                        .onSubmit(move)
                        .accessibilityIdentifier("folder-edit-path")
                } footer: {
                    Text("A folder that is already on \(computer). The agent stops, its conversation and memory go with it, "
                         + "and it starts again there. Nothing in either folder is copied.")
                }
                if moving {
                    Section {
                        HStack { ProgressView().controlSize(.small); Text("Moving…").foregroundColor(.secondary) }
                    }
                }
                if let refused {
                    Section {
                        Label(refused, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("folder-edit-error")
                    }
                }
            }
            .insetGroupedForm()
            .navigationTitle("Working Directory")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("folder-edit-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move", action: move)
                        .disabled(moving || wanted.isEmpty || wanted == session.cwd)
                        .accessibilityIdentifier("folder-edit-move")
                }
            }
        }
        .presentationDetentsMediumLarge()
        .onAppear { path = session.cwd }
    }

    /// Asks the computer to move the session; gone once it has, the
    /// refusal shown if it doesn't.
    private func move() {
        let folder = wanted
        guard !moving, !folder.isEmpty, folder != session.cwd else { return }
        moving = true
        refused = nil
        Task {
            do {
                try await host.moveFolder(session.id, to: folder)
                dismiss()
            } catch {
                refused = VisorAgentServer.problem(error)
            }
            moving = false
        }
    }
}
