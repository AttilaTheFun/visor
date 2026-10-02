import AgentUI
import SwiftUI
import VisorClient
import VisorProtocol

/// Every model a provider offers, by maker, with a search over names,
/// makers and ids at the top.
@MainActor
struct AllModelsSheet: View {
    let catalog: AgentCatalog
    let chosen: String?
    let choose: (AgentModel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var groups: [(name: String, models: [AgentModel])] {
        let query = search.trimmed.lowercased()
        let matching = catalog.models.filter { model in
            query.isEmpty || model.title.lowercased().contains(query) || model.id.lowercased().contains(query)
                || (model.group ?? "").lowercased().contains(query)
        }
        var byGroup: [String: [AgentModel]] = [:]
        for model in matching { byGroup[model.group ?? "Other", default: []].append(model) }
        return byGroup.keys.sorted { $0.lowercased() < $1.lowercased() }.map { name in
            (name, byGroup[name, default: []].sorted { $0.title.lowercased() < $1.title.lowercased() })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField("Search models", text: $search)
                            .autocorrectionDisabled()
                            .keyboardTypeURL()
                            .accessibilityIdentifier("model-search")
                    }
                }
                if groups.isEmpty {
                    Text("No model matches “\(search.trimmed)”.").foregroundColor(.secondary).font(.footnote)
                }
                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.models) { model in
                            ModelRow(model: model, chosen: model.id == chosen) { choose(model) }
                        }
                    }
                }
            }
            .navigationTitle("All Models")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetentsLarge()
    }
}
