// The session's inspector, from the title: what it is, where, and the
// ways out. For a chat, its agent, model and context; for a terminal,
// which window has it.

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct SessionInspector: View {
    @ObservedObject var host: AgentServerConnection
    let session: SessionInfo
    /// A sheet, not a pane: a phone. Only then is there a Done button —
    /// a pane is closed from the toolbar's inspector button.
    let compact: Bool
    let close: () -> Void
    let archive: () -> Void
    let end: () -> Void
    @State private var title = ""
    /// The pause after typing before the title is saved.
    @State private var titleSave: Task<Void, Never>?

    /// Which window a terminal session is drawn for, in words.
    private var terminalWindow: String {
        if host.controlsTerminal(session) {
            return session.mode.terminalSize.map { "This one, \($0.cols) × \($0.rows)" } ?? "This one"
        }
        return session.mode.isTUI ? "Another window" : "None yet"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    TitledField(title: "Title") {
                        TextField(session.agent.title, text: $title)
                            .onSubmit(saveTitle)
                            // Saved as it is typed (after a pause) and when
                            // the inspector goes, not only on Return: a
                            // sheet swiped away never submits.
                            .onChange(of: title) {
                                titleSave?.cancel()
                                titleSave = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 800_000_000)
                                    guard !Task.isCancelled else { return }
                                    saveTitle()
                                }
                            }
                    }
                    if session.agent.isShell {
                        LabeledContent("Kind", value: "Terminal")
                        LabeledContent("Folder", value: session.cwd)
                        LabeledContent("Computer", value: host.record.name.isEmpty ? host.record.address : host.record.name)
                        LabeledContent("Window", value: terminalWindow)
                    } else {
                        LabeledContent("Agent", value: session.agent.title)
                        LabeledContent("Model", value: host.modelTitle(for: session) + (session.effort.map { " " + AgentCatalog.effortTitle($0) } ?? ""))
                        LabeledContent("Folder", value: session.cwd)
                        LabeledContent("Computer", value: host.record.name.isEmpty ? host.record.address : host.record.name)
                        if let used = session.contextUsed {
                            LabeledContent("Context", value: "\(used / 1000)k of \((session.contextLimit ?? 0) / 1000)k")
                        }
                        LabeledContent("State", value: session.busy ? "Working" : (session.archived ? "Archived" : "Idle"))
                        // To carry the conversation on in the agent's own
                        // interface: end this session, open a terminal
                        // session, and run this there.
                        if let command = session.resumeCommand {
                            Button { copyToPasteboard(command) } label: { Label("Copy resume command", systemImage: "doc.on.doc") }
                        }
                    }
                }
                Section {
                    // A terminal keeps nothing to come back to: it is ended,
                    // not archived.
                    if !session.agent.isShell { Button("Archive", action: archive) }
                    Button("End session", role: .destructive, action: end)
                } footer: {
                    if session.agent.isShell {
                        Text("Ending the session ends its shell and whatever runs in it.")
                    }
                }
            }
            .insetGroupedForm()
            // Titled only as a sheet: as a pane beside the chat, its title
            // would stand in for the window's, which is the session's.
            .titled("Details", when: compact)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if compact {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
                }
            }
        }
        .onAppear { title = session.title }
        .onDisappear {
            titleSave?.cancel()
            saveTitle()
        }
    }

    /// Renames the session to what is typed, when that is a new name.
    private func saveTitle() {
        let trimmed = title.trimmed
        guard !trimmed.isEmpty, trimmed != session.title else { return }
        host.rename(session.id, title: trimmed)
    }
}
