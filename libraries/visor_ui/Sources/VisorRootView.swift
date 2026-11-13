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
import VisorPasteboard
import VisorProtocol

@MainActor
public struct VisorRootView: View {
    @Environment(VisorStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// The app has been in the background since it was last in front.
    @State private var wasInBackground = false
    @State private var columns: NavigationSplitViewVisibility = .all
    /// What the open session's screen calls when its session is ended.
    @State private var endSession = ViewAction()
    /// What a session's page or row opens: its fork, its branch, its side
    /// questions, a subagent, or another session.
    @State private var openSelection = SelectionAction()
    /// The pages pushed over the open session's chat (SubSessionRoute), and
    /// those to push once a session opened from the list is on screen.
    @State private var subPath: [SubSessionRoute] = []
    @State private var pendingPath: [SubSessionRoute]?
    /// What a fork's or branch's page calls when it is ended there.
    @State private var popSubPage = ViewAction()
    @State private var composing = false
    @State private var renamingSession: SessionTarget?
    @State private var renamingProject: ProjectTarget?
    @State private var deletingSession: SessionTarget?
    /// A session being moved to another computer.
    @State private var migrating: SessionMigration?
    @State private var removingProject: ProjectTarget?
    /// A project whose folder the computer can no longer find.
    @State private var troubled: ProjectTarget?
    /// The same project, once "Locate" is chosen: the picker is open.
    @State private var locating: ProjectTarget?
    @State private var nameDraft = ""
    /// What the sidebar has selected: a session, or a project's archive.
    @State private var selection: ContentSelection?
    @State private var search = ""
    /// The sidebar's list holds the keyboard: the selection is drawn in the
    /// accent (on the Mac an unfocused list draws it grey) and the arrow
    /// keys move through it, as in Mail.
    @FocusState private var sidebarFocused: Bool
    /// Messages matching the search, from every computer connected.
    @State private var messageHits: [(host: AgentServerConnection, hit: SearchHit)] = []
    /// The window's one trailing pane: Settings, or a session's details
    /// (TrailingPane).
    @State private var pane: TrailingPane?
    /// The computer whose page Settings has open, by its id.
    @State private var settingsComputer: String?

    /// Visor, Settings and all.
    public init() {}

    /// Whether Settings is open: the pane showing it. Opened, it takes the
    /// pane from a session's details; closed, the pane closes.
    private var settingsPresented: Binding<Bool> {
        Binding(get: { pane == .settings }, set: { open in
            if open { pane = .settings } else if pane == .settings { pane = nil }
        })
    }

    /// Whether the pane is open, whatever it shows.
    private var paneOpen: Binding<Bool> {
        Binding(get: { pane != nil }, set: { open in
            guard !open else { return }
            pane = nil
        })
    }

    /// The session on screen, for notifications and for keeping it.
    private func noteViewing(_ value: ContentSelection?) {
        let session = value?.session
        store.noteViewing(serverID: session?.serverID, sessionID: session?.sessionID)
    }

    /// Settings with its title and Done, where it is a sheet.
    private var settingsSheet: some View {
        NavigationStack {
            VisorSettingsView(computer: $settingsComputer, inSheet: true)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { settingsPresented.wrappedValue = false }
                            .accessibilityIdentifier("settings-done")
                    }
                }
        }
    }

    /// What the pane shows: Settings, or a session's details (in a sheet
    /// on a phone, with Settings' title and Done there).
    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .settings:
            if compact {
                settingsSheet
            } else {
                VisorSettingsView(computer: $settingsComputer)
            }
        case .session(let which):
            if let host = store.server(for: which.serverID), let info = host.transcript(for: which.sessionID).info {
                SessionInspector(host: host, session: info, compact: compact,
                                 close: { pane = nil },
                                 archive: { pane = nil; host.archive(which.sessionID) },
                                 end: {
                                     pane = nil
                                     host.end(which.sessionID)
                                     // The session's page goes: the selection's,
                                     // or the page pushed over it.
                                     if selection?.session == which { endSession.run() } else { popSubPage.run() }
                                 })
            }
        case nil:
            EmptyView()
        }
    }

    /// The split view with the pane, where it isn't on the detail column.
    @ViewBuilder private func paneOnSplitView(_ split: some View) -> some View {
        if Compat.paneOnDetailColumn {
            split
        } else {
            split.adaptiveInspector(isPresented: paneOpen, compact: compact) { paneContent }
        }
    }

    /// Settings open at a computer's page.
    private func openSettings(for host: AgentServerConnection) {
        settingsComputer = host.id
        settingsPresented.wrappedValue = true
    }

    private var compact: Bool { sizeClass == .compact }
    private var searching: Bool { !search.trimmed.isEmpty }

    /// The onboarding while it is needed (the default one: while there
    /// are no computers); then the app's account's sign-in while no one is
    /// signed in (a fork's, or the fixture's); the computers otherwise.
    /// Adding a computer is open to all three.
    /// The look Settings › Appearance chose (VisorPreferences), unless a
    /// screenshot fixture names its own; nil follows the device.
    private var colorScheme: ColorScheme? {
        let fixture = VisorFixture.appearance
        if fixture == "dark" { return .dark }
        if fixture == "light" { return .light }
        switch VisorPreferences.shared.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    public var body: some View {
        // What the open session's screen calls when the session is ended
        // there: held across passes, so the screen compares equal.
        endSession.run = { selection = nil }
        openSelection.run = { open($0) }
        popSubPage.run = { if !subPath.isEmpty { subPath.removeLast() } }
        return root
            // Settings › Appearance; screenshots: one look, whatever the
            // device's.
            .preferredColorScheme(colorScheme)
            .sheet(isPresented: Binding(get: { store.addingServer }, set: { store.addingServer = $0 })) {
                AddAgentServerSheet { record in
                    store.add(record)
                    store.addingServer = false
                } cancel: {
                    store.addingServer = false
                }
            }
    }

    @ViewBuilder private var root: some View {
        if VisorFixture.screen == "onboarding" || VisorOnboardings.current.isNeeded(store) {
            // No split view yet, so no pane: Settings is a sheet, opened by
            // the onboarding's own Settings button (the trailing pane in its
            // environment), as every tab of a host has its gear.
            VisorOnboardings.current.view(store)
                .environment(\.trailingPane, $pane)
                .sheet(isPresented: settingsPresented) { settingsSheet }
        } else if let account = VisorAccounts.current, !store.accountSignedIn {
            AccountSignInView(account: account)
        } else {
            computers
        }
    }

    private var computers: some View {
        // No preferred compact column: on a phone the list's selection says
        // what shows, as in Reviews. Bound, SwiftUI set it to the sidebar as
        // a page over the chat was popped, and Back went past the chat.
        // The one trailing pane, at the platform's place: the detail column
        // on a Mac (on the whole split view the detail kept its width and
        // pushed the other columns out), the whole split view elsewhere (on
        // an iPad the detail column's took its navigation title). Attached
        // once: a second inspector beside it, even closed, looped AppKit's
        // layout (TrailingPane).
        paneOnSplitView(NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            if Compat.paneOnDetailColumn {
                detailView.adaptiveInspector(isPresented: paneOpen, compact: compact) { paneContent }
            } else {
                detailView
            }
        }
        .navigationSplitViewStyle(.balanced))
        .environment(\.trailingPane, $pane)
        .sheet(isPresented: $composing) {
            ComposeSessionSheet(store: store) { serverID, id in
                selection = .session(SessionSelection(serverID: serverID, sessionID: id))
            }
        }
        .itemSheet($migrating) { migration in
            MigrationSheet(migration: migration) { id in
                selection = .session(SessionSelection(serverID: migration.to.id, sessionID: id))
            }
        }
        .itemSheet($locating) { target in
            FolderPicker(host: target.host) { cwd in
                target.host.relocateProject(target.cwd, to: cwd)
            }
        }
        .alert("SSH key", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK") { store.notice = nil }
        } message: {
            Text(store.notice ?? "")
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
        .task { await openProbeSession() }
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
            // Another session's chat starts with nothing over it, or with
            // the page it was opened for (a capsule in the list).
            subPath = pendingPath ?? []
            pendingPath = nil
            // A session's inspector open: it follows the selection, so its
            // buttons act on the session shown (visor#363); with no session
            // selected, it closes.
            if case .session = pane { pane = value?.session.map { .session($0) } }
            // Which session is on screen, so a notification about it, with
            // the app in front, is not shown over it.
            noteViewing(value)
        }
        // Gone, and back: no session on screen while it is gone.
        .onDisappear { store.noteViewing(serverID: nil, sessionID: nil) }
        .onAppear { noteViewing(selection) }
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
        }
        // A sign-in link: its computer's page in Settings, where it is
        // signed in to.
        .onChange(of: store.openingSettings) { _, address in
            guard let address, let host = store.server(named: address) else { return }
            store.openingSettings = nil
            openSettings(for: host)
        }
        // Backing out on a phone is deselecting: the row is no longer
        // open, so it is no longer lit, and tapping it opens it again.
    }

    /// Screenshot tests: straight to the screen asked for, without the
    /// animation of getting there (VisorFixture).
    /// For a recording of a session's first open (tools/probes/frames): the
    /// session named at launch (`-visor.probe.open <session id>`), opened
    /// a few seconds in, once its computer has listed it, as a tap in the
    /// sidebar would.
    private func openProbeSession() async {
        let id = VisorFixture.probeSession
        guard !id.isEmpty else { return }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let host = store.servers.first(where: { $0.sessions.contains { $0.id == id } }) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                selection = .session(SessionSelection(serverID: host.id, sessionID: id))
                return
            }
        }
    }

    private func openFixtureScreen() {
        let screen = VisorFixture.screen
        guard !screen.isEmpty else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            switch screen {
            case "chat", "inspector", "models", "learns-earlier", "arrivals", "burst", "torrent", "question", "commands":
                selection = .session(SessionSelection(serverID: VisorFixture.serverID, sessionID: VisorFixture.chatSession))
            case "goal", "earlier":
                selection = .session(SessionSelection(serverID: VisorFixture.serverID, sessionID: VisorFixture.goalSession))
            case "search":
                search = VisorFixture.searchQuery
            case "new-session":
                composing = true
            case "settings":
                // Beside a chat: the case a Mac's layout looped on with two
                // inspectors (TrailingPane).
                selection = .session(SessionSelection(serverID: VisorFixture.serverID, sessionID: VisorFixture.chatSession))
                settingsPresented.wrappedValue = true
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

    /// In one column (a phone) the list is titled, with search and compose
    /// in the bar at the bottom, as Messages has them; beside the detail
    /// (an iPad, the Mac) it has no title, and compose sits at the top with
    /// the sidebar's own button, over the search.
    private var sidebar: some View {
        let compose: (() -> Void)? = store.servers.isEmpty ? nil : { composing = true }
        return ListSearchChrome(text: $search, prompt: "Search sessions", composeLabel: "New session",
                                compose: compact ? compose : nil) {
            outline
        }
        .navigationTitle(compact ? "Sessions" : "")
        .toolbar {
            // Settings, beside the sidebar's toggle (top leading on a phone).
            SettingsInspectorButton(isPresented: settingsPresented)
            if !compact, let compose {
                ToolbarItem(placement: .primaryAction) {
                    Button("New session", systemImage: "square.and.pencil", action: compose)
                }
            }
        }
    }

    /// One section per computer, headed by its name and whether it is
    /// answering: its sessions, the latest activity first; its projects'
    /// archives. A Runner's computers come together, after those added by
    /// hand. The last section adds a computer. Each computer's settings and
    /// the accounts are in Settings (VisorSettingsView). Search narrows the
    /// rows in every section at once.
    private var outline: some View {
        // On a phone the selection is what shows: a session's chat, or the
        // list again once Back clears it.
        List(selection: $selection) {
            ForEach(store.ownServers) { host in
                HostSection(host: host) { host in hostRows(host) }
            }
            // Each Runner's computers.
            ForEach(store.runners) { account in
                ForEach(store.servers(of: account)) { host in
                    HostSection(host: host) { host in hostRows(host) }
                }
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
            }
        }
        .sidebarListStyle(compact: compact)
        .focused($sidebarFocused)
        // Once the window is up and the search field has let the keyboard
        // go (ListSearchChrome takes it back from the field AppKit gives it
        // to).
        .task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            sidebarFocused = true
        }
        // Asked again as a computer connects: a search typed (or opened on)
        // before it was found none of its messages, and kept none.
        .task(id: "\(search.trimmed)|\(store.servers.filter { $0.state == .connected }.count)") { await searchMessages(search.trimmed) }
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

    /// A computer's rows: its sessions and its archives.
    @ViewBuilder private func hostRows(_ host: AgentServerConnection) -> some View {
        let projects = entries(for: host)
        let cards = projects.flatMap { entry in entry.project.sessions.map { SessionCard(host: host, project: entry.project, session: $0) } }
            .sorted { $0.updated > $1.updated }
        let archived = projects.flatMap(\.project.archived)
        // While messages match the search below, a computer with no
        // session named so says nothing.
        if cards.isEmpty && archived.isEmpty && !(searching && messageHits.contains { $0.host === host }) {
            Text(searching ? "Nothing matches “\(search.trimmed)”." : "No sessions yet — tap compose to start one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        ForEach(cards) { card in
            let which = SessionSelection(serverID: host.id, sessionID: card.session.id)
            SessionCardRow(session: card.session, selected: selection == .session(which),
                           subSessions: SubSessionList.items(of: card.session, children: host.children(of: card.session.id)),
                           open: openSelection, serverID: host.id)
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
                Image(systemName: "archivebox").foregroundStyle(.secondary)
                    .frame(width: OutlineMetrics.glyph, height: OutlineMetrics.glyph)
                Text("Archived").lineLimit(1)
                Spacer()
                Text("\(archived.count)").foregroundStyle(.secondary)
            }
            .tag(ContentSelection.hostArchive(serverID: host.id))
            .accessibilityIdentifier("archived-" + host.record.name)
        }
    }

    @ViewBuilder private func sessionMenu(_ card: SessionCard) -> some View {
        let host = card.host, session = card.session
        Button { nameDraft = session.title; renamingSession = SessionTarget(host: host, session: session) } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button { host.archive(session.id) } label: { Label("Archive", systemImage: "archivebox") }
        AgentStateButtons(host: host, session: session)
        // To another computer connected now; this one keeps the session
        // until the user removes it.
        let others = store.servers.filter { $0.id != host.id && $0.state == .connected && $0.migrates }
        if host.migrates, !others.isEmpty {
            Menu {
                ForEach(others, id: \.id) { other in
                    Button(other.record.name) { migrating = SessionMigration(session: session, from: host, to: other) }
                }
            } label: {
                Label("Migrate…", systemImage: "arrow.right.circle")
            }
        }
        // Into a runner's container, the same session carried on there
        // (docs/runners.md); the server says why when it can't.
        if session.agent == .claude {
            Button { host.moveToRunner(session.id) } label: { Label("Move to a Runner", systemImage: "shippingbox") }
        }
        // The command that picks the same conversation up in a terminal
        // on the computer itself.
        if let command = session.resumeCommand {
            Button { Pasteboard.string = command } label: { Label("Copy resume command", systemImage: "doc.on.doc") }
        }
        Divider()
        Button { selection = .project(serverID: host.id, cwd: card.project.cwd) } label: {
            Label("Project Settings", systemImage: "folder")
        }
        Button { openSettings(for: host) } label: {
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
        // One stack, always there, whatever is selected (as Reviews has it):
        // a stack made only for a session, and made again for each, took
        // Back from a page over the chat past the chat to the list on a
        // collapsed phone.
        NavigationStack(path: boundSubPath) {
            detailRoot
                // The detail takes the window's slack, so the sidebar opens at
                // its own width instead of stretching to its maximum. Its one
                // width, on the stack's root content, never on the stack too:
                // two minimums for one column left AppKit's update-constraints
                // pass taking a new minimum each round until it threw
                // (Applications, 9 Nov 2026). The least it lays out in beside
                // Settings; the Mac window's minimum fits the sidebar, this
                // and Settings (VisorMacApp).
                .navigationSplitViewColumnWidth(min: 440, ideal: 720)
                .navigationDestination(for: SubSessionRoute.self) { route in
                    if let which = selection?.session, let host = store.server(for: which.serverID) { subPage(route, host: host) }
                }
        }
    }

    /// The pages as SwiftUI's own NavigationPath, not the typed array: on
    /// the Mac, the typed array bound to the split view's detail column
    /// brought the app down at the first push (SwiftUI's `try!` on
    /// AnyNavigationPath.Error.comparisonTypeMismatch); a NavigationPath
    /// doesn't. SwiftUI only pops them (Back); they are pushed here.
    private var boundSubPath: Binding<NavigationPath> {
        Binding(get: { NavigationPath(subPath) },
                set: { path in if path.count < subPath.count { subPath = Array(subPath.prefix(path.count)) } })
    }

    /// What is selected: a project's settings, an archive, a session's chat,
    /// or nothing.
    @ViewBuilder private var detailRoot: some View {
        Group {
            if case .project(let serverID, let cwd) = selection, let host = store.server(for: serverID),
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
                // The session's chat, with its forks, side questions and
                // subagents pushed over it: Back returns to the chat.
                AgentScreen(host: host, sessionID: which.sessionID, ended: endSession, open: openSelection)
                    .id(which)
            } else {
                EmptyDetail(title: "Nothing selected",
                            subtitle: store.servers.isEmpty ? "Connect a computer first." : "Pick a computer, a project or a session, or tap compose to start one.")
            }
        }
    }

    /// A page pushed over a session's chat.
    @ViewBuilder private func subPage(_ route: SubSessionRoute, host: AgentServerConnection) -> some View {
        switch route {
        case .session(let id): AgentScreen(host: host, sessionID: id, ended: popSubPage, open: openSelection)
        case .side(let id): SideQuestionsScreen(host: host, sessionID: id)
        case .subagent(let id, let agent): SubagentScreen(host: host, sessionID: id, agentID: agent, open: openSelection)
        }
    }

    /// What a page or a row opens. A session's side questions, a subagent,
    /// or a fork or branch are pages over the chat of the session they came
    /// from; anything else is selected.
    private func open(_ target: ContentSelection) {
        switch target {
        case .side(let session):
            push(.side(session.sessionID), over: session)
        case .subagent(let session, let agent):
            push(.subagent(session: session.sessionID, agent: agent), over: session)
        case .session(let which):
            if let host = store.server(for: which.serverID), let parent = host.sessions.first(where: { $0.id == which.sessionID })?.parent {
                push(.session(which.sessionID), over: SessionSelection(serverID: which.serverID, sessionID: parent))
            } else if selection?.session == which {
                subPath = []
            } else {
                selection = target
            }
        default:
            selection = target
        }
    }

    /// `route` over `parent`'s chat: on the stack when that chat is open,
    /// or a page over it is; else that chat is opened with it.
    private func push(_ route: SubSessionRoute, over parent: SessionSelection) {
        if selection?.session == parent {
            subPath = [route]
        } else if selection?.session?.serverID == parent.serverID, let index = subPath.firstIndex(of: .session(parent.sessionID)) {
            subPath = Array(subPath[...index]) + [route]
        } else {
            pendingPath = [route]
            selection = .session(parent)
        }
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
