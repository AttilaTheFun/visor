// The client's shape: two columns. The sidebar is an inset grouped list,
// a section per computer headed by whether it is answering, its sessions
// in it and its settings last. Search runs across every computer at once,
// and the single compose beside it asks which connected computer and
// folder the new session goes to.
// The detail is whatever the sidebar has selected: an agent's page, or a
// project's archive. A phone shows one column at a time.

import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
public struct VisorRootView: View {
    @EnvironmentObject private var store: VisorStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// The app has been in the background since it was last in front.
    @State private var wasInBackground = false
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var composing = false
    @State private var renamingSession: SessionTarget?
    @State private var renamingProject: ProjectTarget?
    @State private var deletingSession: SessionTarget?
    @State private var removingProject: ProjectTarget?
    /// A project whose folder the computer can no longer find.
    @State private var troubled: ProjectTarget?
    /// The same project, once "Locate" is chosen: the picker is open.
    @State private var locating: ProjectTarget?
    @State private var nameDraft = ""
    /// What the sidebar has selected: a session, or a project's archive.
    @State private var selection: ContentSelection?
    @State private var search = ""
    /// Messages matching the search, from every computer connected.
    @State private var messageHits: [(host: AgentServerConnection, hit: SearchHit)] = []
    @State private var linking = false
    @State private var linkResult: String?

    public init() {}

    private var compact: Bool { sizeClass == .compact }
    private var searching: Bool { !search.trimmed.isEmpty }

    public var body: some View {
        SplitView(columns: $columns, compactColumn: $compactColumn) {
            sidebar
        } detail: {
            detailView
        }
        .sheet(isPresented: $store.addingServer) {
            AddAgentServerSheet { record in
                store.add(record)
                store.addingServer = false
            } cancel: {
                store.addingServer = false
            }
        }
        .sheet(isPresented: $composing) {
            ComposeSessionSheet(store: store) { serverID, id in
                selection = .session(SessionSelection(serverID: serverID, sessionID: id))
                if compact { compactColumn = .detail }
            }
        }
        .itemSheet($locating) { target in
            FolderPicker(host: target.host) { cwd in
                target.host.relocateProject(target.cwd, to: cwd)
            }
        }
        .alert("Rename Session", isPresented: presenting($renamingSession)) {
            TextField("Title", text: $nameDraft)
            Button("Cancel", role: .cancel) { renamingSession = nil }
            Button("Rename") {
                if let target = renamingSession, !nameDraft.trimmed.isEmpty {
                    target.host.rename(target.session.id, title: nameDraft.trimmed)
                }
                renamingSession = nil
            }
        }
        .alert("Rename Project", isPresented: presenting($renamingProject)) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) { renamingProject = nil }
            Button("Rename") {
                if let target = renamingProject { target.host.renameProject(target.cwd, to: nameDraft) }
                renamingProject = nil
            }
        } message: {
            Text("A name for this folder in Visor. The folder itself is not renamed; clear the name to use the folder's own again.")
        }
        .alert("Remove this session?", isPresented: presenting($deletingSession)) {
            Button("Cancel", role: .cancel) { deletingSession = nil }
            Button("Remove", role: .destructive) {
                if let target = deletingSession {
                    if selection?.session?.sessionID == target.session.id { selection = nil }
                    target.host.end(target.session.id)
                }
                deletingSession = nil
            }
        } message: {
            Text(Self.removeSessionExplanation(deletingSession?.session))
        }
        .alert("Remove this project?", isPresented: presenting($removingProject)) {
            Button("Cancel", role: .cancel) { removingProject = nil }
            Button("Remove", role: .destructive) {
                if let target = removingProject { target.host.removeProject(target.cwd) }
                removingProject = nil
            }
        } message: {
            Text("Visor forgets \(removingProject?.name ?? "this folder") and stops listing it. The folder and everything in it stay on the computer.")
        }
        .alert("This folder has moved", isPresented: presenting($troubled)) {
            Button("Cancel", role: .cancel) { troubled = nil }
            Button("Locate…") {
                locating = troubled
                troubled = nil
            }
            Button("Delete Project and Sessions", role: .destructive) {
                if let target = troubled {
                    if selection?.serverID == target.host.id { selection = nil }
                    target.host.removeProjectAndSessions(target.cwd)
                }
                troubled = nil
            }
        } message: {
            Text("\(troubled?.host.record.name ?? "The computer") can no longer find \(troubled?.cwd ?? "this folder"). Locate it if it was renamed or moved, or delete the project and the \(troubled?.sessionCount ?? 0) session\(troubled?.sessionCount == 1 ? "" : "s") in it if it is gone for good.")
        }
        .onAppear {
            openFixtureScreen()
            // The transcript's image hook is one closure for the whole
            // app, so it is given the store and told which computer to ask
            // by the reference each picture carries.
            TranscriptImages.render = { [store] reference, maxEdge in
                AnyView(VisorImage(reference: reference, maxEdge: maxEdge, store: store))
            }
            #if os(iOS) || os(macOS)
            // And the bytes themselves, so a picture opened full screen
            // can be handed to a share sheet and saved.
            TranscriptImages.data = { [store] reference in
                await VisorImage.bytes(reference: reference, store: store)
            }
            #endif
        }
        .onChange(of: selection) { _, value in
            if compact { compactColumn = value == nil ? .sidebar : .detail }
            // Which session is on screen, so a notification about it, with
            // the app in front, is not shown over it.
            store.noteViewing(serverID: value?.session?.serverID, sessionID: value?.session?.sessionID)
        }
        // Back in front: a phone dropped every channel when the app left
        // it, so each server is tried or checked now rather than at its
        // next retry.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasInBackground = true
                store.suspend()
            case .active:
                store.resume(afterBackground: wasInBackground)
                wasInBackground = false
            default:
                store.noteInactive()
            }
        }
        // A notification the user opened: its session, on its computer.
        .onChange(of: store.opening) { _, target in
            guard let target, let host = store.server(named: target.computer) else { return }
            store.opening = nil
            selection = .session(SessionSelection(serverID: host.id, sessionID: target.session))
            if compact { compactColumn = .detail }
        }
        // Backing out on a phone is deselecting: the row is no longer
        // open, so it is no longer lit, and tapping it opens it again.
        .onChange(of: compactColumn) { _, column in
            if compact, column == .sidebar, selection != nil { selection = nil }
        }
    }

    /// Screenshot tests: straight to the screen asked for, without the
    /// animation of getting there (VisorFixture).
    private func openFixtureScreen() {
        let screen = VisorFixture.screen
        guard !screen.isEmpty else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            switch screen {
            case "chat", "inspector", "models":
                selection = .session(SessionSelection(serverID: VisorFixture.serverID, sessionID: VisorFixture.chatSession))
                if compact { compactColumn = .detail }
            case "goal", "earlier":
                selection = .session(SessionSelection(serverID: VisorFixture.serverID, sessionID: VisorFixture.goalSession))
                if compact { compactColumn = .detail }
            case "search":
                search = VisorFixture.searchQuery
            default:
                break
            }
        }
    }

    /// An `isPresented` binding over an optional subject: the alert closes
    /// by clearing it.
    private func presenting<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    // MARK: Sidebar — computer, project, session

    private var sidebar: some View {
        ListSearchChrome(text: $search, prompt: "Search sessions", composeLabel: "New session",
                         compose: store.servers.isEmpty ? nil : { composing = true }) {
            outline
        }
    }

    /// One section per computer, headed by its name and whether it is
    /// answering: its sessions, the latest activity first; its projects'
    /// archives; and last, the computer's settings, where it is edited or
    /// removed. The last section adds a computer. Search narrows the rows
    /// in every section at once.
    private var outline: some View {
        List(selection: $selection) {
            ForEach(store.servers) { host in
                HostSection(host: host) { host in hostRows(host) }
            }
            // What was said, as well as what the sessions are called.
            if searching, !messageHits.isEmpty {
                Section {
                    ForEach(messageHits, id: \.hit.id) { item in
                        MessageHitRow(hit: item.hit, computer: store.servers.count > 1 ? item.host.record.name : nil)
                            .tag(ContentSelection.session(SessionSelection(serverID: item.host.id, sessionID: item.hit.session)))
                    }
                } header: {
                    Text("Messages").noHeaderCase()
                }
            }
            // Always last: where another computer comes from.
            Section {
                Button { store.addingServer = true } label: {
                    Label(AgentServerProviderUIs.addTitle + "…", systemImage: "plus").rowLabel()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("add-computer")
                // The servers of the computers here, linked to one another,
                // so their agents reach each other's sessions.
                if store.servers.count > 1 {
                    Button { linkServers() } label: {
                        Label(linking ? "Linking…" : "Link These Computers", systemImage: "link").rowLabel()
                    }
                    .buttonStyle(.plain)
                    .disabled(linking)
                    .accessibilityIdentifier("link-computers")
                }
            }
        }
        .insetGroupedList()
        .task(id: search.trimmed) { await searchMessages(search.trimmed) }
        .alert("Link These Computers", isPresented: presenting($linkResult)) {
            Button("OK") { linkResult = nil }
        } message: {
            Text(linkResult ?? "")
        }
        .navigationTitle("Sessions")
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
    }

    /// Asks every connected computer for the messages that match, a
    /// moment after the typing stops (a new search cancels this one).
    private func searchMessages(_ query: String) async {
        guard query.count > 1 else { messageHits = []; return }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        var found: [(host: AgentServerConnection, hit: SearchHit)] = []
        for host in store.servers where host.state == .connected {
            let hits = (try? await host.search(query)) ?? []
            found += hits.prefix(30).map { (host: host, hit: $0) }
        }
        guard !Task.isCancelled else { return }
        messageHits = found
    }

    private func linkServers() {
        linking = true
        Task {
            let problems = await store.linkServers()
            linkResult = problems.map { "Some links failed:\n" + $0 }
                ?? "The agents on each computer can now list, message and read the sessions on the others."
            linking = false
        }
    }

    /// A computer's rows: its sessions, its archives, its settings.
    @ViewBuilder private func hostRows(_ host: AgentServerConnection) -> some View {
        let projects = entries(for: host)
        let cards = projects.flatMap { entry in entry.project.sessions.map { SessionCard(host: host, project: entry.project, session: $0) } }
            .sorted { $0.updated > $1.updated }
        let archived = projects.flatMap(\.project.archived)
        // While messages match the search below, a computer with no
        // session named so says nothing.
        if cards.isEmpty && archived.isEmpty && !(searching && messageHits.contains { $0.host === host }) {
            Text(searching ? "Nothing matches “\(search.trimmed)”." : "No sessions yet — tap compose to start one.")
                .foregroundColor(.secondary)
                .font(.footnote)
        }
        ForEach(cards) { card in
            let which = SessionSelection(serverID: host.id, sessionID: card.session.id)
            SessionCardRow(session: card.session)
                .tag(ContentSelection.session(which))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button { host.archive(card.session.id) } label: { Label("Archive", systemImage: "archivebox") }
                        .tint(.orange)
                }
                .contextMenu { sessionMenu(card) }
        }
        // The computer's archive: one row, however many ended sessions it
        // holds, wherever they ran.
        if !archived.isEmpty {
            HStack(spacing: OutlineMetrics.gap) {
                Image(systemName: "archivebox").foregroundColor(.secondary)
                    .frame(width: OutlineMetrics.glyph, height: OutlineMetrics.glyph)
                Text("Archived").lineLimit(1)
                Spacer()
                Text("\(archived.count)").foregroundColor(.secondary)
            }
            .tag(ContentSelection.hostArchive(serverID: host.id))
            .accessibilityIdentifier("archived-" + host.record.name)
        }
        let settings = ContentSelection.computer(serverID: host.id)
        HStack(spacing: OutlineMetrics.gap) {
            Image(systemName: "gearshape").foregroundColor(.secondary)
                .frame(width: OutlineMetrics.glyph, height: OutlineMetrics.glyph)
            Text("Computer Settings")
            Spacer()
        }
        .tag(settings)
        .accessibilityIdentifier("computer-settings-" + host.record.name)
    }

    @ViewBuilder private func sessionMenu(_ card: SessionCard) -> some View {
        let host = card.host, session = card.session
        Button { nameDraft = session.title; renamingSession = SessionTarget(host: host, session: session) } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button { host.archive(session.id) } label: { Label("Archive", systemImage: "archivebox") }
        // The command that picks the same conversation up in a terminal
        // on the computer itself.
        if let command = session.resumeCommand {
            Button { copyToPasteboard(command) } label: { Label("Copy resume command", systemImage: "doc.on.doc") }
        }
        Divider()
        Button { selection = .project(serverID: host.id, cwd: card.project.cwd) } label: {
            Label("Project Settings", systemImage: "folder")
        }
        Button { selection = .computer(serverID: host.id) } label: {
            Label("Computer Settings", systemImage: "desktopcomputer")
        }
        Divider()
        Button(role: .destructive) { deletingSession = SessionTarget(host: host, session: session) } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    /// One computer's projects, filtered by the search and sorted by name.
    /// A project whose own name or path matches (or whose computer does)
    /// keeps all its sessions; otherwise only the sessions that match.
    private func entries(for host: AgentServerConnection) -> [ProjectEntry] {
        let query = search.trimmed.lowercased()
        let hostMatches = query.isEmpty
            || host.record.name.lowercased().contains(query)
            || host.record.address.lowercased().contains(query)
        var out: [ProjectEntry] = []
        for project in host.projects {
            if hostMatches || project.name.lowercased().contains(query) || project.cwd.lowercased().contains(query) {
                out.append(ProjectEntry(host: host, project: project))
                continue
            }
            let matches: (SessionInfo) -> Bool = { $0.title.lowercased().contains(query) }
            let sessions = project.sessions.filter(matches)
            let archived = project.archived.filter(matches)
            guard !sessions.isEmpty || !archived.isEmpty else { continue }
            var filtered = project
            filtered.sessions = sessions
            filtered.archived = archived
            out.append(ProjectEntry(host: host, project: filtered))
        }
        return out.sorted { $0.project.name.lowercased() < $1.project.name.lowercased() }
    }

    // MARK: Detail — the agent

    @ViewBuilder private var detailView: some View {
        Group {
            if case .computer(let serverID) = selection, let host = store.server(for: serverID) {
                ComputerSettingsView(host: host, forget: {
                    selection = nil
                    store.remove(host)
                })
                .id(serverID)
            } else if case .project(let serverID, let cwd) = selection, let host = store.server(for: serverID),
                      let project = host.projects.first(where: { $0.cwd == cwd }) {
                ProjectSettingsView(host: host, project: project,
                                    rename: { nameDraft = project.alias ?? ""; renamingProject = ProjectTarget(host: host, project: project) },
                                    locate: { troubled = ProjectTarget(host: host, project: project) },
                                    archive: { selection = .archived(serverID: serverID, cwd: cwd) },
                                    remove: { removingProject = ProjectTarget(host: host, project: project) })
                    .id(serverID + "|" + cwd + "|settings")
            } else if case .archived(let serverID, let cwd) = selection, let host = store.server(for: serverID) {
                ArchivedList(host: host, cwd: cwd, openProject: { selection = .project(serverID: serverID, cwd: $0) })
                    .id(serverID + "|" + cwd)
            } else if case .hostArchive(let serverID) = selection, let host = store.server(for: serverID) {
                ArchivedList(host: host, cwd: nil, openProject: { selection = .project(serverID: serverID, cwd: $0) })
                    .id(serverID + "|archive")
            } else if let which = selection?.session, let host = store.server(for: which.serverID) {
                AgentScreen(host: host, sessionID: which.sessionID, ended: { selection = nil })
                    .id(which)
            } else {
                EmptyDetail(title: "Nothing selected",
                            subtitle: store.servers.isEmpty ? "Connect a computer first." : "Pick a computer, a project or a session, or tap compose to start one.")
            }
        }
        // The detail takes the window's slack, so the sidebar opens at its
        // own width instead of stretching to its maximum.
        .navigationSplitViewColumnWidth(min: 320, ideal: 720)
    }

    /// Removing a session drops Visor's handle, not the agent's own copy.
    static func removeSessionExplanation(_ session: SessionInfo?) -> String {
        let title = session.map { $0.title.isEmpty ? $0.agent.title : $0.title } ?? "This session"
        let agent = session?.agent.title ?? "The agent"
        var text = "\(title) disappears from Visor. \(agent) may still keep the conversation on the computer, and it can be resumed there."
        if let command = session?.resumeCommand { text += " Resume it with: \(command)" }
        return text
    }
}
