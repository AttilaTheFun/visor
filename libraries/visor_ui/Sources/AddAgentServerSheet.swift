import SwiftUI
import VisorClient

/// Adding a server: with one entry (a provider's sign-in, or one that
/// adds another provider's records), its sign-in at once; with several, a
/// choice first, then the chosen one's sign-in.
@MainActor
struct AddAgentServerSheet: View {
    let add: (AgentServerRecord) -> Void
    let cancel: () -> Void
    @State private var chosen: String?

    private var entries: [any AgentServerProviderUI] { AgentServerProviderUIs.all }
    /// The entry whose sign-in is shown: the only one, or the chosen one.
    private var entry: (any AgentServerProviderUI)? {
        entries.count == 1 ? entries.first : entries.first { $0.providerID == chosen }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let entry {
                    entry.addView(add: add)
                        .navigationTitle(entry.addTitle)
                } else {
                    List(entries, id: \.providerID) { entry in
                        Button(entry.title) { chosen = entry.providerID }
                            .accessibilityIdentifier("provider-" + entry.providerID)
                    }
                    .choiceListInSheet(rows: entries.count)
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
