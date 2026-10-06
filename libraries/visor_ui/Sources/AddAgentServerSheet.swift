import SwiftUI
import VisorClient

/// Adding a server: with one provider, its own sign-in at once; with
/// several, a choice of provider first, then the chosen one's sign-in.
@MainActor
struct AddAgentServerSheet: View {
    let add: (AgentServerRecord) -> Void
    let cancel: () -> Void
    @State private var chosen: String?

    private var providers: [any AgentServerProvider] { AgentServerProviders.all }
    /// The provider whose sign-in is shown: the only one, or the chosen one.
    private var provider: (any AgentServerProvider)? {
        providers.count == 1 ? providers.first : providers.first { $0.id == chosen }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let provider {
                    let ui = AgentServerProviderUIs.ui(for: provider.id)
                    ui.addView(add: add)
                        .navigationTitle(ui.addTitle)
                } else {
                    List(providers, id: \.id) { provider in
                        Button(provider.title) { chosen = provider.id }
                            .accessibilityIdentifier("provider-" + provider.id)
                    }
                    .choiceListInSheet(rows: providers.count)
                    .navigationTitle(AgentServerProviderUIs.addTitle)
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            }
        }
    }
}
