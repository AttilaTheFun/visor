// A session's side questions (`/btw`): asked of its agent beside the
// conversation, and answered without going into it, even while the agent
// works. A page of their own, pushed over the session's chat from its row
// above the composer; the row's ✕ ends them.

import AgentUI
import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct SideQuestionsScreen: View {
    var host: AgentServerConnection
    let sessionID: String
    @State private var draft = ""

    /// Read from the list, which says each question and its answer.
    private var info: SessionInfo? { host.sessions.first { $0.id == sessionID } }
    private var questions: [SideQuestion] { info?.side ?? [] }
    private var agent: String { info?.agent.title ?? "The agent" }

    var body: some View {
        AgentView(messages: Self.rows(questions),
                  // Thought over: the row spins, and the next can be asked.
                  activity: questions.contains { !$0.settled } ? "Thinking…" : nil,
                  emptyTitle: "Ask on the Side",
                  emptyBody: "A question about this conversation, answered from what \(agent) knows. It doesn't go into the conversation, and \(agent) keeps working.",
                  draft: $draft, placeholder: "Ask \(agent) on the side…", busy: false, send: ask, stop: {}) {
            EmptyView()
        } attachments: {
            EmptyView()
        }
        .navigationTitle("Side Questions")
        .toolbarTitleDisplayMode(.inline)
    }

    /// Each question as the person's row, and its answer, or why there is
    /// none, as the agent's.
    static func rows(_ questions: [SideQuestion]) -> [TranscriptMessage] {
        questions.flatMap { item -> [TranscriptMessage] in
            var rows = [TranscriptMessage(id: item.id + "-question", role: .user, text: item.question)]
            if let answer = item.answer {
                rows.append(TranscriptMessage(id: item.id + "-answer", role: .assistant, text: answer))
            } else if let failure = item.failure {
                rows.append(TranscriptMessage(id: item.id + "-answer", role: .assistant, text: "No answer: \(failure)"))
            }
            return rows
        }
    }

    private func ask() {
        let question = draft.trimmed
        guard !question.isEmpty else { return }
        draft = ""
        host.askSide(sessionID, question: question)
    }
}
