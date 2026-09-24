// The session's inspector, from the title: what it is, who is driving it,
// and the ways out.
//
// A session is either in the chat, which every client draws for its own
// screen, or in the agent's own terminal, which the computer draws at one
// fixed size for one window. So taking the terminal is taking control:
// the mode carries this client and this window, and the terminal starts
// again for them.

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct SessionInspector: View {
    @ObservedObject var host: HostConnection
    let session: SessionInfo
    /// The room the session's pane has here, in points.
    let window: CGSize
    /// A sheet, not a pane: a phone. Only then is there a Done button —
    /// a pane is closed from the toolbar's inspector button.
    let compact: Bool
    /// Takes control at this size — through the app, which may first ask
    /// about forking a session another process holds.
    let takeControl: (Int, Int) -> Void
    let close: () -> Void
    let archive: () -> Void
    let end: () -> Void
    @State private var title = ""
    /// The pause after typing before the title is saved.
    @State private var titleSave: Task<Void, Never>?
    @State private var taking = false
    @State private var returning = false

    private var mine: Bool { host.controlsTerminal(session) }
    private var elsewhere: Bool { session.mode.isTUI && !mine }
    private var cells: (cols: Int, rows: Int) { TerminalMetrics.cells(in: window) }

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
                            .onChange(of: title) { _ in
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
                    LabeledContent("Computer", value: host.config.name.isEmpty ? host.config.host : host.config.name)
                    if let used = session.contextUsed {
                        LabeledContent("Context", value: "\(used / 1000)k of \((session.contextLimit ?? 0) / 1000)k")
                    }
                    LabeledContent("State", value: session.busy ? "Working" : (session.archived ? "Archived" : "Idle"))
                    if let command = session.resumeCommand {
                        Button { copyToPasteboard(command) } label: { Label("Copy resume command", systemImage: "doc.on.doc") }
                    }
                }
                Section {
                    if mine {
                        LabeledContent("Interface", value: "Your terminal")
                        if let size = session.mode.terminalSize {
                            LabeledContent("Window", value: "\(size.cols) × \(size.rows)")
                        }
                        Button("Return to chat") { returning = true }
                    } else if elsewhere {
                        LabeledContent("Interface", value: "A terminal, in another window")
                        Button("Take control") { taking = true }
                        Button("Return to chat") { returning = true }
                    } else {
                        LabeledContent("Interface", value: "Chat")
                        Button("Take control of the terminal") { taking = true }
                    }
                } header: {
                    Text("Interface")
                } footer: {
                    Text(footnote)
                }
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
        .alert("Take control of the terminal?", isPresented: $taking) {
            Button("Cancel", role: .cancel) {}
            // Closed first: the screen this sheet sits over is about to
            // become the terminal, and a sheet left open across that is
            // left behind, blank, with no way to dismiss it.
            Button("Take control") {
                close()
                takeControl(cells.cols, cells.rows)
            }
        } message: {
            Text(takeMessage)
        }
        .alert("Hand the session back to the chat?", isPresented: $returning) {
            Button("Cancel", role: .cancel) {}
            Button("Return to chat") {
                close()
                host.returnToChat(session.id)
            }
        } message: {
            Text("The terminal ends and the session carries on in the chat, where every window can read it. Anything half-typed in the terminal is lost.")
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

    private var footnote: String {
        if mine {
            return "The agent's own interface, drawn on the computer for this window: slash commands, plan mode, and its own permission prompts. Other windows can read the session but not drive it."
        }
        if elsewhere {
            return "Another window is driving the agent's terminal. This one shows what has been said; take control to drive it here, at this window's size."
        }
        return "The chat is drawn by each window for its own screen. The agent's own terminal is drawn once, on the computer, for the window that takes it — \(cells.cols) × \(cells.rows) here."
    }

    private var takeMessage: String {
        let size = "\(cells.cols) × \(cells.rows)"
        if elsewhere {
            return "The agent's terminal starts again at \(size) for this window. Whoever is driving it now loses it, and anything half-typed there is lost."
        }
        return "The session leaves the chat and carries on in the agent's own terminal at \(size), drawn for this window. A turn in flight is interrupted."
    }
}

extension View {
    /// A navigation title, or none: a pane inside a window must not name
    /// the window.
    @ViewBuilder func titled(_ title: String, when show: Bool) -> some View {
        if show { navigationTitle(title) } else { self }
    }
}
