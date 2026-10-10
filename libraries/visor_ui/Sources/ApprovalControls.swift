import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// In the composer while a tool call waits: what it is, Allow, Deny.
@MainActor
struct ApprovalControls: View {
    let request: ApprovalRequest
    /// Where the answer goes: the computer and the session, compared by
    /// identity and value rather than two closures, which never compare
    /// equal.
    let host: AgentServerConnection
    let sessionID: String

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
            Button("Deny") { host.approve(sessionID, id: request.id, allow: false) }
                .agentPillButton().accessibilityIdentifier("deny")
            Button("Allow") { host.approve(sessionID, id: request.id, allow: true) }
                .agentPillButton().foregroundColor(.green).accessibilityIdentifier("allow")
        }
    }
}
