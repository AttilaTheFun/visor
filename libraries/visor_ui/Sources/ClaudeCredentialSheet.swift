// Sign In to Claude… for a computer's Sessions container (docs/containers.md,
// "Claude's credential"): the token `claude setup-token` printed, pasted
// here and kept by the computer as its agent-proxy's, which adds it to each
// of the container's requests to api.anthropic.com. Its shape is the
// server's to check; what it says in refusing is shown, the sheet kept open.
// Nothing of it is kept on this device, and the computer never gives it
// back.

import SwiftUI
import VisorClient

@MainActor
public struct ClaudeCredentialSheet: View {
    /// The computer, as the instructions name it.
    let computer: String
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var saving = false
    @State private var problem: String?

    public init(computer: String, save: @escaping (String) async throws -> Void) {
        self.computer = computer
        self.save = save
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Run `claude setup-token` in Terminal on \(computer), then paste the token here.")
                    PasswordField("Token", text: $token)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("container-claude-token")
                } footer: {
                    Text("The container's agents reach Claude through Visor's agent-proxy, which adds this token to each of their requests. "
                         + "It's kept with the computer's secrets: the container and its agents never see it.")
                }
                if let problem {
                    Section {
                        Text(problem)
                            .foregroundColor(.red)
                            .accessibilityIdentifier("container-claude-error")
                    }
                }
            }
            .insetGroupedForm()
            .navigationTitle("Sign In to Claude")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("container-claude-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save", action: submit)
                            .disabled(token.trimmed.isEmpty)
                            .accessibilityIdentifier("container-claude-save")
                    }
                }
            }
        }
    }

    /// Sent to the computer: the sheet closes once it's kept, or says why not.
    private func submit() {
        saving = true
        problem = nil
        let given = token.trimmed
        Task {
            do {
                try await save(given)
                token = ""
                dismiss()
            } catch {
                problem = VisorAgentServer.problem(error)
                saving = false
            }
        }
    }
}
