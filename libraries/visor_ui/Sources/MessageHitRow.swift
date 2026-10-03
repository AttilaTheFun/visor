import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// A message that matched the search: its words, and whose they are.
@MainActor
struct MessageHitRow: View {
    let hit: SearchHit
    /// The computer's name, when there is more than one to tell apart.
    let computer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.snippet)
                .lineLimit(2)
            Text(([hit.role == "user" ? "You" : hit.role == "assistant" ? "Agent" : "Tool",
                   hit.title.isEmpty ? AttachmentKind.fileName(hit.cwd) : hit.title] + (computer.map { [$0] } ?? []))
                .joined(separator: " · "))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("message-hit")
    }
}
