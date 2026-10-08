import SwiftUI
import VisorClient

/// A provider's views: how a new server of its kind is signed in, and how
/// a saved one's settings are shown. The Visor server's are the connection code
/// form and the address-and-password form; a fork registers its own
/// (`AgentServerProviderUIs.register`) beside its `AgentServerProvider`,
/// and shows whatever its sign-in needs — a web view, a device code, a
/// company's own SSO. The sheet around the view is the app's.
///
/// Each is an entry in the add sheet, and what it adds may be another
/// provider's: a company's front registers an entry of its own (an id no
/// provider has) whose sign-in adds Visor Server records, which then show
/// the Visor server's settings.
@MainActor
public protocol AgentServerProviderUI {
    /// The provider it draws for (`AgentServerProvider.id`), or its own
    /// id for an entry that adds another provider's records.
    var providerID: String { get }
    /// What its entry in the add sheet is called; the provider's title by
    /// default.
    var title: String { get }
    /// What the add sheet is called ("Add Computer").
    var addTitle: String { get }
    /// Signs a new server in. Calls `add` with its record once it is
    /// authenticated — of any provider: the store saves and connects it.
    func addView(add: @escaping (AgentServerRecord) -> Void) -> AnyView
    /// A saved server's settings, in the detail column: its credentials
    /// where they can be edited or renewed, its state, and `forget`.
    func settingsView(for server: AgentServerConnection, forget: @escaping () -> Void) -> AnyView
}

public extension AgentServerProviderUI {
    var title: String { AgentServerProviders.provider(for: providerID)?.title ?? addTitle }
}
