// One of a session's subagents: its conversation, read from the computer
// every two seconds while it works, and a composer whose words go to the
// session's agent to pass on to it (Claude's subagents are reached only
// through the agent that sent them off). A page of its own, opened from
// the session's row above its composer or the capsule under its card.

import AgentUI
import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct SubagentScreen: View {
    var host: AgentServerConnection
    let sessionID: String
    let agentID: String
    let open: SelectionAction
    @State private var draft = ""
    @State private var rows: [TranscriptEntry] = []
    @State private var loaded = false

    /// Read from the list, which says whether it still works.
    private var session: SessionInfo? { host.sessions.first { $0.id == sessionID } }
    private var subagent: SubagentInfo? { session?.subagents.first { $0.id == agentID } }
    private var running: Bool { subagent?.running ?? false }
    private var title: String {
        guard let subagent else { return "Subagent" }
        return subagent.description.isEmpty ? subagent.type : subagent.description
    }
    private var parent: ContentSelection { .session(SessionSelection(serverID: host.id, sessionID: sessionID)) }
    private var agentName: String { session?.agent.title ?? "the agent" }

    var body: some View {
        AgentView(messages: rows.map { TranscriptMessage($0, host: host.id, id: $0.id) }, activity: running ? "Working…" : nil,
                  emptyTitle: loaded ? title : "Loading…",
                  emptyBody: loaded ? "Nothing said yet." : "Fetching its conversation from \(host.record.name).",
                  draft: $draft,
                  placeholder: running ? "Message it, through \(agentName)…" : "It has finished.",
                  busy: false, send: send, stop: {}) {
            EmptyView()
        } attachments: {
            EmptyView()
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            // Back to the session: a mark of its own, not Back's chevron,
            // which goes to the list.
            ToolbarItem(placement: .primaryAction) {
                Button { open(parent) } label: {
                    Label(session?.title ?? "Session", systemImage: "arrow.uturn.left")
                }
                .accessibilityLabel("Back to \(session?.title ?? "the session")")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Close") {
                    host.closeSubagent(sessionID, agent: agentID)
                    open(parent)
                }
            }
        }
        // Read again every two seconds while it works, and once after.
        .task(id: running) {
            repeat {
                if let read = await host.subagentTranscript(sessionID, agent: agentID) {
                    if read != rows { rows = read }
                    loaded = true
                }
                guard running else { return }
                try? await Task.sleep(for: .seconds(2))
            } while !Task.isCancelled
        }
    }

    private func send() {
        let words = draft.trimmed
        guard running, !words.isEmpty else { return }
        draft = ""
        host.messageSubagent(sessionID, agent: agentID, text: words)
    }
}
