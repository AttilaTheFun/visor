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
                    .lineLimit(1)
                    .agentPillButton().foregroundColor(.accentColor).accessibilityIdentifier("answer")
                    .layoutPriority(1)
            }
        } else {
            permission
        }
    }

    private var permission: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundColor(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.tool).font(.subheadline.weight(.medium)).lineLimit(1)
                if !request.summary.isEmpty {
                    Text(request.summary).font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Whole words in a narrow composer (a window 320 points wide,
            // or 340 beside the sidebar: "Den y", "Al- low"): what the tool
            // is gives way first, cut in its middle.
            Button("Deny") { host.approve(sessionID, id: request.id, allow: false) }
                .lineLimit(1)
                .agentPillButton().accessibilityIdentifier("deny")
                .layoutPriority(1)
            Button("Allow") { host.approve(sessionID, id: request.id, allow: true) }
                .lineLimit(1)
                .agentPillButton().foregroundColor(.green).accessibilityIdentifier("allow")
                .layoutPriority(1)
        }
    }
}
