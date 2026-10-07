import SwiftUI
import VisorClient

/// How the client signs in to a server, in the connect and settings
/// forms: a choice of authenticator when there is one (none, the
/// password, a fork's SSO), then the chosen one's rows.
@MainActor
struct AuthenticationRows: View {
    let address: String
    @Binding var authentication: String
    @Binding var secret: String

    var body: some View {
        if AgentServerAuthenticators.all.count > 1 {
            Picker("Sign in with", selection: $authentication) {
                ForEach(AgentServerAuthenticators.all, id: \.id) { authenticator in
                    Text(authenticator.title).tag(authenticator.id)
                }
            }
            .accessibilityIdentifier("authentication")
        }
        AgentServerAuthenticatorUIs.ui(for: authentication).fields(address: address, secret: $secret)
    }
}
