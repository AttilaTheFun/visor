import SwiftUI
import VisorClient

/// The authenticators' rows this build knows, by authenticator: the
/// password's and none's shipped; a fork registers its own at launch,
/// beside its `AgentServerAuthenticator`.
@MainActor
public enum AgentServerAuthenticatorUIs {
    private static var registry: [any AgentServerAuthenticatorUI] = [PasswordAuthenticatorUI(), NoAuthenticatorUI()]

    public static func register(_ ui: any AgentServerAuthenticatorUI) {
        registry.removeAll { $0.authenticatorID == ui.authenticatorID }
        registry.append(ui)
    }

    /// The rows for an authenticator; an unknown one gets the password's.
    static func ui(for authenticatorID: String) -> any AgentServerAuthenticatorUI {
        registry.first { $0.authenticatorID == authenticatorID } ?? registry[0]
    }
}
