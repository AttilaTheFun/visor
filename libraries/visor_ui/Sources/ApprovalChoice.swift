import AgentUI
import SwiftUI
import VisorClient
import VisorProtocol

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
