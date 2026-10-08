import SwiftUI
import VisorClient

/// The providers' views this build knows, by provider. The Visor server's
/// are the ones shipped; a fork registers its own at launch, with its
/// provider.
@MainActor
public enum AgentServerProviderUIs {
    private static var registry: [any AgentServerProviderUI] = [VisorAgentServerProviderUI()]

    /// The entries of the add sheet: each provider's views, and those that
    /// add another provider's records.
    public static var all: [any AgentServerProviderUI] { registry }

    public static func register(_ ui: any AgentServerProviderUI) {
        registry.removeAll { $0.providerID == ui.providerID }
        registry.append(ui)
    }

    /// What adding a server is called: the one entry's words ("Add
    /// Computer"), or "Add Agent Server" when there is a choice.
    public static var addTitle: String {
        registry.count == 1 ? registry[0].addTitle : "Add Agent Server"
    }

    /// The views for a provider; an unknown one gets the first's.
    static func ui(for providerID: String) -> any AgentServerProviderUI {
        registry.first { $0.providerID == providerID } ?? registry[0]
    }
}
