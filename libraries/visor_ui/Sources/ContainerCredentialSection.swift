// A computer's Sessions container on its page in Settings: whether its
// agents' Claude credential is set (agent-proxy's, which adds it to their
// requests: docs/containers.md, "Claude's credential"), its presence alone,
// as `GET /api/container` says; Sign In to Claude… (ClaudeCredentialSheet)
// and Sign Out. Shown for a computer whose server says (0.69 and later).

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct ContainerCredentialSection: View {
    var host: AgentServerConnection
    @State private var signingIn = false
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        if let set = host.container?.claudeCredential {
            Section {
                LabeledContent("Claude sign-in") {
                    Text(set ? "Set" : "Not set")
                        .accessibilityIdentifier("container-claude-state")
                }
                Button("Sign In to Claude…") { signingIn = true }
                    .accessibilityIdentifier("container-sign-in")
                    .sheet(isPresented: $signingIn) {
                        ClaudeCredentialSheet(computer: host.record.name.isEmpty ? host.record.address : host.record.name) { token in
                            try await host.setContainerClaudeCredential(token)
                        }
                    }
                if set {
                    Button("Sign Out", role: .destructive, action: signOut)
                        .disabled(working)
                        .accessibilityIdentifier("container-claude-sign-out")
                }
                if let problem { Text(problem).font(.footnote).foregroundColor(.red) }
            } header: {
                Text("Sessions Container")
            } footer: {
                Text("The container's agents reach Claude through Visor's agent-proxy, with a token from `claude setup-token` kept on this "
                     + "computer. They never see it; without one, they can't reach Claude.")
            }
        }
    }

    private func signOut() {
        working = true
        problem = nil
        Task {
            do {
                try await host.setContainerClaudeCredential(nil)
            } catch {
                problem = VisorAgentServer.problem(error)
            }
            working = false
        }
    }
}
