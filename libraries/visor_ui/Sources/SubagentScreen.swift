// One of a session's subagents: its conversation, read from the computer
// every two seconds while it works, and a composer whose words go to the
// session's agent to pass on to it (Claude's subagents are reached only
// through the agent that sent them off) while it works, and once it has
// finished, go on with its conversation as a session of its own, whose
// page takes this one's place. A page of its own, opened from the
// session's row above its composer or the capsule under its card.

import AgentUI
import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct SubagentScreen: View {
    var host: AgentServerConnection
    let sessionID: String
    let agentID: String
    /// Opens the session it goes on as.
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
    private var agentName: String { session?.agent.title ?? "the agent" }

    var body: some View {
        AgentView(messages: rows.map { TranscriptMessage($0, host: host.id, id: $0.id) }, activity: running ? "Working…" : nil,
                  emptyTitle: loaded ? title : "Loading…",
                  emptyBody: loaded ? "Nothing said yet." : "Fetching its conversation from \(host.record.name).",
                  draft: $draft,
                  placeholder: running ? "Message it, through \(agentName)…" : "Go on with it as a session of its own…",
                  busy: false, send: send, stop: {}) {
            EmptyView()
        } attachments: {
            EmptyView()
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
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
        guard loaded, !words.isEmpty else { return }
        draft = ""
        guard !running else {
            host.messageSubagent(sessionID, agent: agentID, text: words)
            return
        }
        Task {
            do {
                let id = try await host.continueSubagent(sessionID, agent: agentID, text: words)
                open(.session(SessionSelection(serverID: host.id, sessionID: id)))
            } catch {
                // Said in the window (the connection's error); the words
                // are kept to send again.
                if draft.isEmpty { draft = words }
            }
        }
    }
}
