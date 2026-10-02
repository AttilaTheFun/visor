import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// In the composer while a tool call waits: what it is, Allow, Deny.
@MainActor
struct ApprovalControls: View {
    let request: ApprovalRequest
    let allow: () -> Void
    let deny: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundColor(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.tool).font(.subheadline.weight(.medium))
                if !request.summary.isEmpty {
                    Text(request.summary).font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Deny", action: deny).agentPillButton().accessibilityIdentifier("deny")
            Button("Allow", action: allow).agentPillButton().foregroundColor(.green).accessibilityIdentifier("allow")
        }
    }
}
