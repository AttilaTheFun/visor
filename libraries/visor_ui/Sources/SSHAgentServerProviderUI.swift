import SwiftUI
import VisorClient

/// A server reached over SSH: `user@host` and the password to add one,
/// the same to edit, and this device's key to put in the user's
/// authorized keys.
public struct SSHAgentServerProviderUI: AgentServerProviderUI {
    public let providerID = SSHAgentServerProvider.name
    public let addTitle = "Add Computer over SSH"
    public init() {}

    public func addView(add: @escaping (AgentServerRecord) -> Void) -> AnyView {
        AnyView(SSHConnectForm(connect: add))
    }

    public func settingsView(for server: AgentServerConnection, forget: @escaping () -> Void) -> AnyView {
        AnyView(SSHSettingsForm(host: server, forget: forget))
    }
}
