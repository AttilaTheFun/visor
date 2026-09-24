// How the session runs: whether it asks before acting, which model it
// uses, and how hard that model thinks. Every tap applies at once (the
// host restarts Claude with the new flags once idle; Codex takes them on
// its next turn).

import AgentUI
import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct ModelSheet: View {
    @ObservedObject var host: HostConnection
    let session: SessionInfo
    @Environment(\.dismiss) private var dismiss
    @State private var browsingAll = false

    private var catalog: AgentCatalog? { host.catalog(for: session.agent) }
    /// The model chosen; else the one the agent said it ran; else the
    /// provider's default.
    private var currentModel: AgentModel? {
        if let chosen = session.model { return catalog?.model(matching: chosen) }
        if let reported = session.reportedModel, let model = catalog?.model(matching: reported) { return model }
        return catalog?.model(matching: nil)
    }
    private var efforts: [String] { currentModel?.efforts ?? catalog?.models.first?.efforts ?? [] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ApprovalChoice(title: "Auto Approve",
                                   detail: "The agent runs without asking. Nobody is at the computer to answer, so this is how a session starts.",
                                   chosen: session.skipPermissions) {
                        host.setPermissions(session.id, skip: true)
                    }
                    ApprovalChoice(title: "Manually Approve",
                                   detail: session.agent == .claude
                                       ? "Edits go through; anything else waits for you here."
                                       : "The agent works inside its workspace sandbox.",
                                   chosen: !session.skipPermissions) {
                        host.setPermissions(session.id, skip: false)
                    }
                } header: {
                    Text("Approval")
                }
                if let catalog, catalog.models.contains(where: { !$0.listed }) {
                    // A long catalog (OpenRouter): what the session runs,
                    // apart; then suggestions; then everything.
                    Section("Current Model") {
                        if let currentModel {
                            ModelRow(model: currentModel, showGroup: true, chosen: true) {}
                        } else {
                            Text(session.model ?? "The agent's default").foregroundColor(.secondary)
                        }
                    }
                    Section("Suggested") {
                        ForEach(catalog.models.filter(\.listed)) { model in
                            ModelRow(model: model, showGroup: true, chosen: currentModel?.id == model.id) {
                                host.setSettings(session.id, model: model.id, effort: session.effort)
                            }
                        }
                        Button { browsingAll = true } label: {
                            HStack {
                                Text("All Models")
                                Spacer()
                                Text("\(catalog.models.count)").foregroundColor(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("all-models")
                    }
                } else {
                    Section {
                        if let catalog {
                            ForEach(catalog.models) { model in
                                ModelRow(model: model, chosen: currentModel?.id == model.id) {
                                    host.setSettings(session.id, model: model.id, effort: session.effort)
                                }
                            }
                        } else {
                            Text("The host did not send a model list for \(session.agent.title).").foregroundColor(.secondary)
                        }
                    } header: {
                        Text("Model")
                    } footer: {
                        if currentModel == nil {
                            Text("\(session.agent.title)'s default for this account; it is checked once the first turn says which it is.")
                        }
                    }
                }
                if !efforts.isEmpty {
                    Section {
                        ForEach(efforts, id: \.self) { effort in
                            Button {
                                host.setSettings(session.id, model: session.model, effort: effort)
                            } label: {
                                HStack {
                                    Text(AgentCatalog.effortTitle(effort))
                                    Spacer()
                                    if (session.effort ?? currentModel?.defaultEffort) == effort {
                                        Image(systemName: "checkmark").foregroundColor(.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Effort")
                    } footer: {
                        Text(session.agent == .claude
                             ? "Claude restarts with the new setting once its current turn ends; the conversation continues."
                             : "Codex uses the new setting from its next turn.")
                    }
                }
                if let used = session.contextUsed {
                    let limit = session.contextLimit ?? (session.agent == .claude ? 1_000_000 : 272_000)
                    Section {
                        HStack {
                            Text(ContextRing.summary(used: used, limit: limit))
                            Spacer()
                            Text("\(Int((Double(used) / Double(max(limit, 1))) * 100))%")
                                .foregroundColor(.secondary)
                        }
                        if session.agent == .claude {
                            Button {
                                host.sendMessage(session.id, text: "/compact")
                                dismiss()
                            } label: {
                                Label("Compact the conversation", systemImage: "square.and.arrow.down").rowLabel()
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("compact")
                        }
                    } header: {
                        Text("Context")
                    } footer: {
                        Text(session.agent == .claude
                             ? "Compacting asks Claude to summarise what has been said so far and carry on from the summary."
                             : "Codex manages its own context; this is what its last turn carried.")
                    }
                }
            }
            .navigationTitle(session.agent.title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetentsMediumLarge()
        .sheet(isPresented: $browsingAll) {
            if let catalog {
                AllModelsSheet(catalog: catalog, chosen: currentModel?.id) { model in
                    host.setSettings(session.id, model: model.id, effort: session.effort)
                    browsingAll = false
                }
            }
        }
    }
}

/// A model to pick: its name (with its maker, in a list that mixes
/// makers), its price or description, and a check when it is in use.
@MainActor
struct ModelRow: View {
    let model: AgentModel
    var showGroup = false
    let chosen: Bool
    let choose: () -> Void

    private var detail: String? {
        let parts = [showGroup ? model.group : nil, model.subtitle].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: choose) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                    if let detail {
                        Text(detail).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if chosen { Image(systemName: "checkmark").foregroundColor(.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

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

/// One of the two ways a session can run, as a row that shows which it is.
@MainActor
struct ApprovalChoice: View {
    let title: String
    let detail: String
    let chosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundColor(.secondary).lineLimit(3)
                }
                Spacer()
                if chosen { Image(systemName: "checkmark").foregroundColor(.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("approval-" + title)
    }
}
