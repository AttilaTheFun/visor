import SwiftUI
import VisorClient

/// A provider's views: how a new server of its kind is signed in, and how
/// a saved one's settings are shown. Tailscale's are the connection code
/// form and the address-and-password form; a fork registers its own
/// (`AgentServerProviderUIs.register`) beside its `AgentServerProvider`,
/// and shows whatever its sign-in needs — a web view, a device code, a
/// company's own SSO. The sheet around the view is the app's.
@MainActor
public protocol AgentServerProviderUI {
    /// The provider it draws for (`AgentServerProvider.id`).
    var providerID: String { get }
    /// What the add sheet is called ("Add Computer").
    var addTitle: String { get }
    /// Signs a new server in. Calls `add` with its record once it is
    /// authenticated: the store saves and connects it.
    func addView(add: @escaping (AgentServerRecord) -> Void) -> AnyView
    /// A saved server's settings, in the detail column: its credentials
    /// where they can be edited or renewed, its state, and `forget`.
    func settingsView(for server: AgentServerConnection, forget: @escaping () -> Void) -> AnyView
}
