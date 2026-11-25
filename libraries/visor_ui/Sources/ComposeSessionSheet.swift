// The one compose, beside the search: everything a session needs before it
// exists — which server, which folder, which agent, and what to call it.
// The folder is picked from the computer's projects or browsed for; a
// server that sets sessions up its own way offers its named choices in
// place of folders, and asks for the first message the session starts with.
// A server with Shireworks offers a container in place of a folder: the agent
// runs there, a repository cloned into it.
// A computer whose Sessions container takes sessions offers it as where
// the session runs (docs/containers.md, "Placing sessions"): Claude Code,
// in a folder of its own there, its model and effort chosen here.
// Or a session is restored: one imported from a session archive (Import…,
// here or the Mac's File › Import…) or backed up on the computer, started
// again there on its own conversation.
// Sessions start in auto mode (no permission prompts — nobody is at the
// computer to answer them); the chat's model sheet switches to manual.

import Foundation
import NavigationUI
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import VisorClient
import VisorProtocol

@MainActor
struct ComposeSessionSheet: View {
    var store: VisorStore
    /// The computer and the new session's id.
    let started: (String, String) -> Void
    /// Opened on Restore (the fixture's `restore`), or on Restore with the
    /// file picker open (the Mac's File › Import…).
    var startsOnRestore = false
    var importsAtOnce = false
    @Environment(\.dismiss) private var dismiss
    @State private var serverID = ""
    @State private var cwd = ""
    @State private var agent: AgentKind = .claude
    @State private var title = ""
    @State private var browsing = false
    /// A new conversation, the agent's own resumed, or a session restored.
    @State private var conversation: Conversation = .new
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
    /// The sessions to restore: each imported or backed-up session.
    @State private var restorable: [Restorable] = []
    @State private var loadingRestorable = false
    /// The one chosen (Restorable's id).
    @State private var restoreChoice: String?
    /// The file picker for a session archive to import is open.
    @State private var importing = false
    @State private var importJob: SessionImport?
    /// The sheet has opened on Restore as it was asked to (startsOnRestore).
    @State private var openedOnRestore = false
    /// Where it runs: on the computer, or in its Sessions container.
    @State private var inContainer = false
    /// The model and effort a session in the container starts with: ""
    /// for Claude Code's own.
    @State private var containerModel = ""
    @State private var containerEffort = ""

    private enum Conversation: Hashable { case new, resume, restore }

    /// One session of a backup the computer keeps, imported or backed up.
    private struct Restorable: Identifiable {
        let backup: SessionBackup
        let item: SessionBackupItem
        var id: String { backup.path + "|" + item.id }
    }

    private var resuming: Bool { conversation == .resume }
    private var restoring: Bool { conversation == .restore }

    /// Only a computer that is answering can start a session.
    private var host: AgentServerConnection? {
        store.connectedServers.first { $0.id == serverID } ?? store.connectedServers.first
    }
    private var starting: SessionStarting { host?.starting ?? .inFolders }
    /// Where the session starts: the folder, or the server's choice.
    private var place: String { starting.fromChoices ? choiceID : cwd.trimmed }
    /// Picking up an agent's own session needs a folder to look in and a
    /// session that starts without a message.
    private var canResume: Bool { starting == .inFolders }
    /// Restoring needs a computer that keeps imported and backed-up
    /// sessions and restores one by itself.
    private var canRestore: Bool { host?.archives == true }
    /// The sessions on the computer now, archived too: one of them isn't
    /// restored over (Logan's rule: remove it first).
    private var sessionsHere: Set<String> {
        Set((host?.projects ?? []).flatMap { $0.sessions + $0.archived }.map(\.id))
    }
    /// The computer's Sessions container is offered for a new conversation
    /// while it takes sessions (as Migrate… offers it).
    private var offersContainer: Bool { host?.takesContainerSessions == true && starting == .inFolders && conversation == .new }
    /// In the container: Claude Code, in a folder the server gives it
    /// there (`<Sessions>/Claude/<id>`), so no folder to pick.
    private var containerChosen: Bool { inContainer && offersContainer }
    private var claudeModels: [AgentModel] { host?.catalog(for: .claude)?.models.filter(\.listed) ?? [] }
    /// The efforts of the model chosen for the container, or of Claude
    /// Code's own.
    private var containerEfforts: [String] {
        let catalog = host?.catalog(for: .claude)
        return (catalog?.models.first(where: { $0.id == containerModel }) ?? catalog?.model(matching: nil))?.efforts ?? []
    }
    private var available: Set<AgentKind> {
        Set((host?.catalogs ?? []).filter(\.available).map(\.agent))
    }
    private var ready: Bool {
        if restoring { return host != nil && !waiting && restorable.contains { $0.id == restoreChoice && !sessionsHere.contains($0.item.id) } }
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
                if let host, offersContainer { placeSection(host) }
                if restoring {
                    // Restoring: the session's own folder, agent and name.
                    EmptyView()
                } else if let host, starting.fromChoices {
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
                } else if host != nil, !containerChosen {
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
                    if !restoring {
                        Picker("Agent", selection: $agent) {
                            ForEach(AgentKind.allCases, id: \.self) { kind in
                                Text(pickerTitle(for: kind)).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        // The container runs Claude Code alone.
                        .disabled(containerChosen)
                    }
                    if canResume || canRestore {
                        Picker("Conversation", selection: $conversation) {
                            Text("New").tag(Conversation.new)
                            if canResume { Text("Resume").tag(Conversation.resume) }
                            if canRestore { Text("Restore").tag(Conversation.restore) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("conversation")
                    }
                }
                if restoring, let host { restoreSection(host) }
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
                if !restoring {
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
                }
                if starting.withFirstMessage && !restoring {
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
                        Button(restoring ? "Restore" : "Start", action: start)
                            .disabled(!ready)
                            .accessibilityIdentifier("start")
                    }
                }
            }
        }
        .presentationDetentsLarge()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.visorSession]) { result in
            if case .success(let url) = result { importArchive(url) }
        }
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
            openOnRestore()
        }
        // The computer answers after the sheet opens (a launch's): Restore
        // is offered, and opened, once it does.
        .onChange(of: canRestore) { openOnRestore() }
        .onChange(of: serverID) {
            useLatestProject()
            choiceID = ""
            useChoices()
            resumable = []
            if restoring { loadRestorable() }
        }
        .onChange(of: host?.startChoices ?? []) { useChoices() }
        // The computer's projects arrive after the sheet opens: the latest
        // stands in until a folder is picked.
        .onChange(of: recentProjects.first?.cwd) { if !placePicked { useLatestProject() } }
        .onChange(of: conversation) {
            if resuming { loadResumable() }
            if restoring { loadRestorable() }
        }
        .onChange(of: agent) { if resuming { loadResumable() } }
        .onChange(of: inContainer) { if inContainer { agent = .claude } }
        .onChange(of: containerModel) { if !containerEfforts.contains(containerEffort) { containerEffort = "" } }
        .onChange(of: cwd) { if resuming { loadResumable() } }
    }

    /// A kind as the picker names it: marked when this computer cannot
    /// run it, its tool not installed.
    private func pickerTitle(for kind: AgentKind) -> String {
        guard !available.contains(kind), !(host?.catalogs.isEmpty ?? true) else { return kind.title }
        return "\(kind.title) (not installed)"
    }

    private var defaultTitle: String {
        // As the server names one in its container.
        if containerChosen { return "Claude Code (container)" }
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

    /// Where the session runs, the computer or its Sessions container (as
    /// Migrate… names them); in the container, its model and effort, and
    /// where it works there.
    @ViewBuilder private func placeSection(_ host: AgentServerConnection) -> some View {
        Section {
            Picker("Runs on", selection: $inContainer) {
                Text(MigratePlaces.name(of: host)).tag(false)
                Text(MigratePlaces.containerName(of: host)).tag(true)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("compose-place")
            if containerChosen {
                Picker("Model", selection: $containerModel) {
                    Text("Default").tag("")
                    ForEach(claudeModels) { model in
                        Text(model.title).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("compose-model")
                if !containerEfforts.isEmpty {
                    Picker("Effort", selection: $containerEffort) {
                        Text("Default").tag("")
                        ForEach(containerEfforts, id: \.self) { effort in
                            Text(AgentCatalog.effortTitle(effort)).tag(effort)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("compose-effort")
                }
            }
        } header: {
            Text("Where")
        } footer: {
            if containerChosen {
                Text("Claude Code only. It works in a folder of its own in the Sessions container, Claude/‹session› on the Sessions volume.")
                    .accessibilityIdentifier("compose-place-note")
            }
        }
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

    /// The sessions the computer keeps to restore, each to choose, and the
    /// way to import another.
    @ViewBuilder private func restoreSection(_ host: AgentServerConnection) -> some View {
        Section {
            if loadingRestorable {
                HStack { ProgressView().controlSize(.small); Text("Looking…").foregroundColor(.secondary) }
            } else if restorable.isEmpty {
                Text("No imported or backed-up sessions on \(host.record.name) yet.").foregroundColor(.secondary)
            }
            ForEach(restorable) { entry in
                let here = sessionsHere.contains(entry.item.id)
                Button { restoreChoice = entry.id } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.item.title.isEmpty ? entry.item.id : entry.item.title).lineLimit(2)
                            Text(Self.detail(of: entry.backup, here: here, now: Date().timeIntervalSince1970))
                                .font(.caption).foregroundColor(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if restoreChoice == entry.id { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                        else { Color.clear.frame(width: 1) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(here)
                .accessibilityIdentifier("restore-" + entry.item.id)
            }
            Button { importing = true } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .disabled(importJob?.phase == .importing)
            .accessibilityIdentifier("import-archive")
            if let importJob {
                switch importJob.phase {
                case .importing:
                    ProgressView(value: importJob.progress) { Text("Importing \(importJob.file.lastPathComponent)…") }
                case .failed(let problem):
                    Text(problem).foregroundColor(.red).accessibilityIdentifier("import-error")
                case .done:
                    EmptyView()
                }
            }
        } header: {
            Text("Restore")
        } footer: {
            Text("Sessions imported from a session archive (.visorsession) or backed up on this computer. Restoring starts one again "
                 + "here on its own conversation, in its own folder; a session still here is removed first. The computer it came from is left as it is.")
        }
    }

    /// "Imported from Mini, 30 min ago", "Backed up 1 day ago", or why it
    /// can't be restored now.
    private static func detail(of backup: SessionBackup, here: Bool, now: Double) -> String {
        if here { return "On this computer now: remove it first to restore it." }
        let ago = UsageWords.ago(now - backup.created)
        return backup.imported ? "Imported from \(backup.from.isEmpty ? "a session archive" : backup.from), \(ago)" : "Backed up \(ago)"
    }

    /// Restore chosen, and the file picker opened, where the sheet was
    /// asked to open so: once, as soon as the computer offers it.
    private func openOnRestore() {
        guard startsOnRestore || importsAtOnce, canRestore, !openedOnRestore else { return }
        openedOnRestore = true
        conversation = .restore
        importing = importsAtOnce
    }

    /// The sessions of every backup the computer keeps, newest first.
    private func loadRestorable() {
        guard let host, host.archives else { return }
        loadingRestorable = true
        Task {
            let kept = (try? await host.sessionBackups()) ?? []
            restorable = kept.flatMap { backup in backup.sessions.filter(\.kept).map { Restorable(backup: backup, item: $0) } }
            loadingRestorable = false
            if restoreChoice == nil || !restorable.contains(where: { $0.id == restoreChoice }) {
                restoreChoice = restorable.first { !sessionsHere.contains($0.item.id) }?.id
            }
        }
    }

    /// The file picked imported into the computer's backups store, then
    /// listed and chosen.
    private func importArchive(_ url: URL) {
        guard let host else { return }
        let job = SessionImport(file: url, host: host)
        importJob = job
        Task {
            let began = Compat.beginFileAccess(url)
            await job.run()
            Compat.endFileAccess(url, began)
            guard case .done(let backup) = job.phase else { return }
            if let item = backup.sessions.first { restoreChoice = backup.path + "|" + item.id }
            loadRestorable()
        }
    }

    /// The session chosen restored on the computer, and opened.
    private func restore(on host: AgentServerConnection) {
        guard let entry = restorable.first(where: { $0.id == restoreChoice }) else { return }
        waiting = true
        failure = nil
        Task {
            do {
                let item = try await host.restoreSession(entry.item.id, from: entry.backup.path)
                guard let item, item.outcome.hasPrefix("Restored") else {
                    failure = item?.outcome ?? "Nothing was restored."
                    waiting = false
                    return
                }
                dismiss()
                started(host.id, entry.item.id)
            } catch {
                failure = "\(error)"
                waiting = false
            }
        }
    }

    private func start() {
        guard let host else { return }
        if restoring { return restore(on: host) }
        if containerChosen { return startInContainer(on: host) }
        waiting = true
        failure = nil
        let place = place
        Task {
            do {
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

    /// A Claude Code session started in the computer's Sessions container,
    /// and opened once its agent has started there; the server's refusal
    /// shown here, the sheet kept open.
    private func startInContainer(on host: AgentServerConnection) {
        waiting = true
        failure = nil
        Task {
            do {
                let id = try await host.startInContainer(title: title.trimmed, model: containerModel.isEmpty ? nil : containerModel,
                                                         effort: containerEffort.isEmpty ? nil : containerEffort)
                dismiss()
                started(host.id, id)
            } catch {
                failure = VisorAgentServer.problem(error)
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
