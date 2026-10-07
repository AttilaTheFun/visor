import SwiftUI
import VisorClient

/// A Visor server's views: a connection code (or an address and password)
/// to add one, and its address and password to edit.
public struct VisorAgentServerProviderUI: AgentServerProviderUI {
    public let providerID = VisorAgentServerProvider.name
    public let addTitle = "Add Computer"
    public init() {}

    public func addView(add: @escaping (AgentServerRecord) -> Void) -> AnyView {
        AnyView(ConnectForm(connect: add))
    }

    public func settingsView(for server: AgentServerConnection, forget: @escaping () -> Void) -> AnyView {
        AnyView(ComputerSettingsForm(host: server, forget: forget))
    }
}
