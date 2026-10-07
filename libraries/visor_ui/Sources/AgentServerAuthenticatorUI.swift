import SwiftUI
import VisorClient

/// An authenticator's rows in the sign-in form: what gets the credential
/// the record keeps (`secret`). The password's is a password field; a
/// fork's SSO is a button that runs its sign-in and sets the token. The
/// form around the rows is the app's: the address, the Connect button.
@MainActor
public protocol AgentServerAuthenticatorUI {
    /// The authenticator it draws for (`AgentServerAuthenticator.id`).
    var authenticatorID: String { get }
    /// The rows, for a server at `address`; `secret` is the credential.
    func fields(address: String, secret: Binding<String>) -> AnyView
}

/// The password: typed, or "if asked" when the computer may ask nothing.
public struct PasswordAuthenticatorUI: AgentServerAuthenticatorUI {
    public let authenticatorID = PasswordAuthenticator.name
    public init() {}
    public func fields(address: String, secret: Binding<String>) -> AnyView {
        AnyView(TitledField(title: "Password (if asked)") {
            PasswordField("Only if the computer asks", text: secret)
                .accessibilityIdentifier("password")
        })
    }
}

/// Nothing to type: the path is the proof.
public struct NoAuthenticatorUI: AgentServerAuthenticatorUI {
    public let authenticatorID = NoAuthenticator.name
    public init() {}
    public func fields(address: String, secret: Binding<String>) -> AnyView {
        AnyView(Text("No sign-in: the computer lets in whoever reaches it, by a path of your own.")
            .font(.footnote).foregroundColor(.secondary))
    }
}
