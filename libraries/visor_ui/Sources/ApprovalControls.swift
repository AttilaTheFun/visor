import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// In the composer while a tool call waits: what it is, Allow, Deny; or,
/// when the agent asks the user something, the question and Answer, which
/// opens the questions (`QuestionSheet`).
@MainActor
struct ApprovalControls: View {
    let request: ApprovalRequest
    /// Where the answer goes: the computer and the session, compared by
    /// identity and value rather than two closures, which never compare
    /// equal.
    let host: AgentServerConnection
    let sessionID: String
    /// Whether the questions are open.
    @Binding var answering: Bool

    var body: some View {
        if let question = request.questions?.first {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(question.header.isEmpty ? "Question" : question.header).font(.subheadline.weight(.medium))
                    Text(question.question).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Answer") { answering = true }
                    .agentPillButton().foregroundColor(.accentColor).accessibilityIdentifier("answer")
            }
        } else {
            permission
        }
    }

    private var permission: some View {
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
