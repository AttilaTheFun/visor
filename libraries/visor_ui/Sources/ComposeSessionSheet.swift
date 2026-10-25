// The one compose, beside the search: everything a session needs before it
// exists — which server, which folder, which agent, and what to call it.
// The folder is picked from the computer's projects or browsed for; a
// server that sets sessions up its own way offers its named choices in
// place of folders, and asks for the first message the session starts with.
// A server with oss offers a container in place of a folder: the agent
// runs there, a repository cloned into it.
// Sessions start in auto mode (no permission prompts — nobody is at the
// computer to answer them); the chat's model sheet switches to manual.

import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct ComposeSessionSheet: View {
    var store: VisorStore
    /// The computer and the new session's id.
    let started: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var serverID = ""
    @State private var cwd = ""
    @State private var agent: AgentKind = .claude
    @State private var title = ""
    @State private var browsing = false
    @State private var resuming = false
    @State private var resumable: [ResumableSession] = []
    @State private var resumableLoad: Task<Void, Never>?
    @State private var loadingResumable = false
    @State private var resumeID = ""
    /// Asking the computer to start it; the sheet waits, and keeps what
    /// went wrong rather than opening a session that is not there.
    @State private var waiting = false
    @State private var failure: String?
    /// The server's choice, where it offers choices in place of folders.
    @State private var choiceID = ""
    /// The first message, where the server starts a session only with one.
    @State private var message = ""
    /// A folder was picked here: the latest project no longer stands in.
    @State private var placePicked = false
    /// The agent runs in a Linux container on the computer, which sees the
    /// folder, rather than on the computer itself.
    @State private var inContainer = false

    /// Only a computer that is answering can start a session.
    private var host: AgentServerConnection? {
        store.connectedServers.first { $0.id == serverID } ?? store.connectedServers.first
    }
    private var starting: SessionStarting { host?.starting ?? .inFolders }
    /// The computer can run the agent in a container, and it is asked to.
    private var containerChosen: Bool { inContainer && (host?.containersAvailable ?? false) }
    /// Where the session starts: the folder, or the server's choice.
    private var place: String { starting.fromChoices ? choiceID : cwd.trimmed }
    /// Picking up an agent's own session needs a folder to look in and a
    /// session that starts without a message.
    private var canResume: Bool { starting == .inFolders && !containerChosen }
    private var available: Set<AgentKind> {
        Set((host?.catalogs ?? []).filter(\.available).map(\.agent))
    }
    private var ready: Bool {
        if containerChosen { return host != nil && !waiting }
        return host != nil && !waiting && !place.isEmpty && !(resuming && canResume && resumeID.trimmed.isEmpty)
            && (!starting.withFirstMessage || !message.trimmed.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.connectedServers.isEmpty {
                    Section {
                        Text("No computer is connected. Sessions start on a computer that is answering; check Computers.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                // Which server, when there is a choice; one connected
                // server is where the session goes.
                if store.connectedServers.count > 1 {
                    Section("Computer") {
                        Picker("Computer", selection: $serverID) {
                            ForEach(store.connectedServers) { host in
                                Text(host.record.name.isEmpty ? host.record.address : host.record.name).tag(host.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("computer")
                    }
                }
                // On the computer itself, or in a container on it: a row
                // each, which wrap at any text size (a segment's words are
                // cut short at the larger ones: "In a Contain…").
                if let host, host.containersAvailable, !starting.fromChoices {
                    Section {
                        Picker("Runs", selection: $inContainer) {
                            Text("On the Computer").tag(false)
                            Text("In a Container").tag(true)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .accessibilityIdentifier("where")
                    } header: {
                        Text("Runs")
                    } footer: {
                        if inContainer {
                            Text("The agent runs in a Linux container on the computer, which sees the project's folder and Xcode, and nothing else of it.")
                        }
                    }
                }
                if let host, starting.fromChoices {
                    Section("Start From") {
                        if host.startChoices.isEmpty {
                            Text("No choices from this server yet.").foregroundColor(.secondary)
                        } else {
                            Picker("Start from", selection: $choiceID) {
                                ForEach(host.startChoices) { choice in
                                    Text(choice.title).tag(choice.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("choice")
                        }
                    }
                } else if host != nil {
                    // The folder chosen (the latest project's until another
                    // is picked), and the row that opens the browser for
                    // another.
                    Section("Project") {
                        ChosenProject(name: recentProjects.first { $0.cwd == cwd }?.name
                                          ?? AgentServerConnection.Project(cwd: cwd, sessions: []).folderName,
                                      path: cwd)
                        Button { browsing = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder")
                                    .foregroundColor(.accentColor)
                                Text("Choose Folder…")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("project")
                    }
                }
                Section {
                    Picker("Agent", selection: $agent) {
                        ForEach(AgentKind.allCases, id: \.self) { kind in
                            Text(pickerTitle(for: kind)).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    if canResume {
                        Picker("Conversation", selection: $resuming) {
                            Text("New").tag(false)
                            Text("Resume").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                if resuming && canResume {
                    Section {
                        TextField("Session id", text: $resumeID)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("resume-id")
                        if loadingResumable {
                            HStack { ProgressView().controlSize(.small); Text("Looking…").foregroundColor(.secondary) }
                        } else if resumable.isEmpty {
                            Text("No \(agent.title) sessions found in this folder.").foregroundColor(.secondary)
                        }
                        ForEach(resumable) { session in
                            Button {
                                resumeID = session.id
                                if title.trimmed.isEmpty { title = session.title }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title).lineLimit(2)
                                        Text(session.id).font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    if resumeID == session.id { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                                    else { Color.clear.frame(width: 1) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Resume")
                    } footer: {
                        Text("The agent's own sessions started in this folder, newest first; or paste an id.")
                    }
                }
                Section {
                    // The default as the field's prompt, its name hidden: a
                    // Mac's form shows a field's title as a label beside it.
                    TextField("Name", text: $title, prompt: Text(defaultTitle))
                        .labelsHidden()
                        .accessibilityIdentifier("title")
                } header: {
                    Text("Name")
                } footer: {
                    Text("Optional.")
                }
                if starting.withFirstMessage {
                    Section {
                        TextField("What the agent should do", text: $message, axis: .vertical)
                            .lineLimit(3...8)
                            .accessibilityIdentifier("first-message")
                    } header: {
                        Text("First message")
                    } footer: {
                        Text("This server starts a session with its first message.")
                    }
                }
                if let failure {
                    Section {
                        Text(failure)
                            .foregroundColor(.red)
                            .accessibilityIdentifier("start-error")
                    } header: {
                        Text("Could not start")
                    }
                }
            }
            .insetGroupedForm()
            .navigationTitle("New Session")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if waiting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Start", action: start)
                            .disabled(!ready)
                            .accessibilityIdentifier("start")
                    }
                }
            }
        }
        .presentationDetentsLarge()
        .sheet(isPresented: $browsing) {
            if let host {
                FolderPicker(host: host, start: cwd) { chosen in
                    host.addProject(chosen)
                    cwd = chosen
                    placePicked = true
                }
            }
        }
        .onAppear {
            if host?.id != serverID { serverID = store.connectedServers.first?.id ?? "" }
            if cwd.isEmpty { useLatestProject() }
            useChoices()
            if !available.contains(agent), let first = AgentKind.allCases.first(where: available.contains) { agent = first }
        }
        .onChange(of: serverID) {
            useLatestProject()
            choiceID = ""
            useChoices()
            resumable = []
        }
        .onChange(of: host?.startChoices ?? []) { useChoices() }
        // The computer's projects arrive after the sheet opens: the latest
        // stands in until a folder is picked.
        .onChange(of: recentProjects.first?.cwd) { if !placePicked { useLatestProject() } }
        .onChange(of: resuming) { if resuming { loadResumable() } }
        .onChange(of: agent) { if resuming { loadResumable() } }
        .onChange(of: cwd) { if resuming { loadResumable() } }
    }

    /// A kind as the picker names it: marked when this computer cannot
    /// run it, its tool not installed.
    private func pickerTitle(for kind: AgentKind) -> String {
        // A container's agents are its image's, not the computer's.
        guard !containerChosen, !available.contains(kind), !(host?.catalogs.isEmpty ?? true) else { return kind.title }
        return "\(kind.title) (not installed)"
    }

    private var defaultTitle: String {
        let siblings = host?.projects.first { $0.cwd == place }?.sessions.filter { $0.agent == agent }.count ?? 0
        return "\(agent.title) \(siblings + 1)"
    }

    /// The computer's projects, the most recently used first: its folders
    /// that are still there, by their sessions' latest activity.
    private var recentProjects: [AgentServerConnection.Project] {
        guard let host else { return [] }
        func latest(_ project: AgentServerConnection.Project) -> Double {
            (project.sessions + project.archived).map { $0.updated ?? $0.created }.max() ?? 0
        }
        return Array(host.projects.filter { !$0.missing && $0.cwd != "~" }.sorted { latest($0) > latest($1) }.prefix(6))
    }

    /// Where a new session starts unless another is picked: the project
    /// used last, or the home folder on a computer with none.
    private func useLatestProject() {
        if let latest = recentProjects.first { cwd = latest.cwd } else { useHome() }
    }

    /// The computer's home folder, by its full path once the computer
    /// has said what `~` is.
    private func useHome() {
        cwd = "~"
        guard let host else { return }
        Task {
            guard let resolved = try? await host.folders(at: "~").path, !resolved.isEmpty, cwd == "~" else { return }
            cwd = resolved
        }
    }

    /// The server's first choice, once it has said them; asked for when it
    /// has not.
    private func useChoices() {
        guard let host, starting.fromChoices else { return }
        if host.startChoices.isEmpty { Task { await host.loadStartChoices() } }
        if !host.startChoices.contains(where: { $0.id == choiceID }) { choiceID = host.startChoices.first?.id ?? "" }
    }

    /// The sessions to resume for the agent and folder as they stand: an
    /// answer for an earlier choice is not shown over a later one.
    private func loadResumable() {
        guard let host, !cwd.trimmed.isEmpty else { return }
        loadingResumable = true
        resumableLoad?.cancel()
        resumableLoad = Task {
            let found = (try? await host.resumable(agent: agent, cwd: cwd)) ?? []
            guard !Task.isCancelled else { return }
            resumable = found
            loadingResumable = false
        }
    }

    private func start() {
        guard let host else { return }
        waiting = true
        failure = nil
        let place = place
        Task {
            do {
                if containerChosen {
                    let id = try await host.startInContainer(agent: agent, cwd: place, title: title.trimmed, skipPermissions: true)
                    host.addProject(place)
                    dismiss()
                    started(host.id, id)
                    return
                }
                let id = try await host.start(agent: agent, cwd: place, title: title.trimmed, skipPermissions: true,
                                              resume: resuming && canResume ? resumeID.trimmed : nil,
                                              firstMessage: starting.withFirstMessage ? message.trimmed : nil)
                host.addProject(place)
                dismiss()
                started(host.id, id)
            } catch {
                failure = "\(error)"
                waiting = false
            }
        }
    }
}

/// The folder the session starts in, as a row: its name and its path.
@MainActor
private struct ChosenProject: View {
    let name: String
    let path: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
        }
        .accessibilityIdentifier("project-chosen")
    }
}
