import SwiftUI
import VisorClient

/// The Mac's views: a connection code (or a Tailscale name and password)
/// to add one, and its address and password to edit.
public struct TailscaleAgentServerProviderUI: AgentServerProviderUI {
    public let providerID = TailscaleAgentServerProvider.name
    public let addTitle = "Add Computer"
    public init() {}

    public func addView(add: @escaping (AgentServerRecord) -> Void) -> AnyView {
        AnyView(ConnectForm(connect: add))
    }

    public func settingsView(for server: AgentServerConnection, forget: @escaping () -> Void) -> AnyView {
        AnyView(ComputerSettingsForm(host: server, forget: forget))
    }
}
