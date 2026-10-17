// The session's inspector, from the title: what it is, where, and the
// ways out: its agent and model, and what it has used of its context and
// its account's limits.

import SwiftUI
import VisorClient
import VisorPasteboard
import VisorProtocol

@MainActor
struct SessionInspector: View {
    var host: AgentServerConnection
    let session: SessionInfo
    /// A sheet, not a pane: a phone. Only then is there a Done button —
    /// a pane is closed from the toolbar's inspector button.
    let compact: Bool
    let close: () -> Void
    let archive: () -> Void
    let end: () -> Void
    @State private var title = ""
    /// The session's title as last put in the field: what is typed is a
    /// rename only where it differs from this, so a field left as it was
    /// never renames the session back.
    @State private var shown = ""
    /// The pause after typing before the title is saved.
    @State private var titleSave: Task<Void, Never>?

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
                    LabeledContent("Agent", value: session.agent.title)
                    LabeledContent("Model", value: host.modelTitle(for: session) + (session.effort.map { " " + AgentCatalog.effortTitle($0) } ?? ""))
                    LabeledContent("Folder", value: session.cwd)
                    LabeledContent("Computer", value: host.record.name.isEmpty ? host.record.address : host.record.name)
                    LabeledContent("State", value: session.busy ? "Working" : (session.archived ? "Archived" : "Idle"))
                    // The agent and what it runs, as its host says.
                    if let memory = session.memory { LabeledContent("Memory", value: MigrationSheet.size(Int(clamping: memory))) }
                    // To carry the conversation on in the agent's own
                    // interface: end this session, and run this in a
                    // terminal on the computer.
                    if let command = session.resumeCommand {
                        Button { Pasteboard.string = command } label: { Label("Copy resume command", systemImage: "doc.on.doc") }
                    }
                }
                SessionUsageSection(session: session, account: host.catalog(for: session.agent)?.account)
                Section {
                    Button("Archive", action: archive)
                    Button("End session", role: .destructive, action: end)
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
        .onAppear {
            title = session.title
            shown = session.title
        }
        // The account's limits as they stand now, not as a turn last left
        // them: each time the inspector shows a session.
        .task(id: session.id) { host.refreshAccount(session.agent) }
        // Renamed elsewhere (the sidebar, another device): the field
        // follows, unless a name of the user's own is being typed in it.
        .onChange(of: session.title) {
            if title == shown { title = session.title }
            shown = session.title
        }
        .onDisappear {
            titleSave?.cancel()
            saveTitle()
        }
    }

    /// Renames the session to what is typed, when the user typed a new name.
    private func saveTitle() {
        let trimmed = title.trimmed
        guard !trimmed.isEmpty, trimmed != session.title, title != shown else { return }
        host.rename(session.id, title: trimmed)
    }
}
