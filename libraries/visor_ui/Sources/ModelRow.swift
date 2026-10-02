import AgentUI
import SwiftUI
import VisorClient
import VisorProtocol

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
