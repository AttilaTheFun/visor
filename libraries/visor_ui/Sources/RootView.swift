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
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
public struct VisorRootView: View {
    @EnvironmentObject private var store: VisorStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var composing = false
    @State private var settingsHost: HostConnection?
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

    public init() {}

    private var compact: Bool { sizeClass == .compact }
    private var searching: Bool { !search.trimmed.isEmpty }

    public var body: some View {
        SplitView(columns: $columns, compactColumn: $compactColumn) {
            sidebar
        } detail: {
            detailView
        }
        .sheet(isPresented: $store.addingComputer) {
            NavigationStack {
                ConnectForm { config in
                    store.add(config)
                    store.addingComputer = false
                }
                .navigationTitle("Add Computer")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.addingComputer = false } }
                }
            }
        }
        .sheet(isPresented: $composing) {
            ComposeSessionSheet(store: store) { hostID, id in
                selection = .session(SessionSelection(hostID: hostID, sessionID: id))
                if compact { compactColumn = .detail }
            }
        }
        .itemSheet($settingsHost) { host in
            ComputerSettingsSheet(host: host, forget: {
                if selection?.hostID == host.id { selection = nil }
                store.remove(host)
            })
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
                    if selection?.hostID == target.host.id { selection = nil }
                    target.host.removeProjectAndSessions(target.cwd)
                }
                troubled = nil
            }
        } message: {
            Text("\(troubled?.host.config.name ?? "The computer") can no longer find \(troubled?.cwd ?? "this folder"). Locate it if it was renamed or moved, or delete the project and the \(troubled?.sessionCount ?? 0) session\(troubled?.sessionCount == 1 ? "" : "s") in it if it is gone for good.")
        }
        .onAppear {
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
        .onChange(of: selection) { value in
            if compact { compactColumn = value == nil ? .sidebar : .detail }
        }
        // Backing out on a phone is deselecting: the row is no longer
        // open, so it is no longer lit, and tapping it opens it again.
        .onChange(of: compactColumn) { column in
            if compact, column == .sidebar, selection != nil { selection = nil }
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
                         compose: store.hosts.isEmpty ? nil : { composing = true }) {
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
            ForEach(store.hosts) { host in
                HostSection(host: host) { host in hostRows(host) }
            }
            // Always last: where another computer comes from.
            Section {
                Button { store.addingComputer = true } label: {
                    Label("Add Computer…", systemImage: "plus").rowLabel()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("add-computer")
            }
        }
        .insetGroupedList()
        .navigationTitle("Sessions")
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
    }

    /// A computer's rows: its sessions, its archives, its settings.
    @ViewBuilder private func hostRows(_ host: HostConnection) -> some View {
        let projects = entries(for: host)
        let cards = projects.flatMap { entry in entry.project.sessions.map { SessionCard(host: host, project: entry.project, session: $0) } }
            .sorted { $0.updated > $1.updated }
        let archives = projects.filter { !$0.project.archived.isEmpty }
        if cards.isEmpty && archives.isEmpty {
            Text(searching ? "Nothing matches “\(search.trimmed)”." : "No sessions yet — tap compose to start one.")
                .foregroundColor(.secondary)
                .font(.footnote)
        }
        ForEach(cards) { card in
            let which = SessionSelection(hostID: host.id, sessionID: card.session.id)
            SessionCardRow(host: host, project: card.project, session: card.session)
                .tag(ContentSelection?.some(.session(which)))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button { host.archive(card.session.id) } label: { Label("Archive", systemImage: "archivebox") }
                        .tint(.orange)
                }
                .contextMenu { sessionMenu(card) }
        }
        // Each folder's archive: one row, however many ended sessions it holds.
        ForEach(archives) { entry in
            let which = ContentSelection.archived(hostID: host.id, cwd: entry.project.cwd)
            HStack(spacing: OutlineMetrics.gap) {
                Image(systemName: "archivebox").foregroundColor(.secondary)
                    .frame(width: OutlineMetrics.glyph, height: OutlineMetrics.glyph)
                Text("Archived · \(entry.project.name)").lineLimit(1)
                Spacer()
                Text("\(entry.project.archived.count)").foregroundColor(.secondary)
            }
            .tag(ContentSelection?.some(which))
            .contextMenu { projectMenu(entry) }
            .accessibilityIdentifier("archived-" + entry.project.name)
        }
        let settings = ContentSelection.computer(hostID: host.id)
        HStack(spacing: OutlineMetrics.gap) {
            Image(systemName: "gearshape").foregroundColor(.secondary)
                .frame(width: OutlineMetrics.glyph, height: OutlineMetrics.glyph)
            Text("Computer Settings")
            Spacer()
        }
        .tag(ContentSelection?.some(settings))
        .accessibilityIdentifier("computer-settings-" + host.config.name)
    }

    @ViewBuilder private func projectMenu(_ entry: ProjectEntry) -> some View {
        Button { selection = .project(hostID: entry.host.id, cwd: entry.project.cwd) } label: {
            Label("Project Settings", systemImage: "gearshape")
        }
        Button { nameDraft = entry.project.alias ?? ""; renamingProject = entry.target } label: {
            Label("Rename Project", systemImage: "pencil")
        }
        Button { copyToPasteboard(entry.project.cwd) } label: { Label("Copy folder path", systemImage: "doc.on.doc") }
        if entry.project.missing {
            Button { troubled = entry.target } label: { Label("Locate…", systemImage: "questionmark.folder") }
        }
        if entry.project.isEmpty {
            Button(role: .destructive) { removingProject = entry.target } label: { Label("Remove Project", systemImage: "trash") }
        }
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
        Button { selection = .project(hostID: host.id, cwd: card.project.cwd) } label: {
            Label("Project Settings", systemImage: "folder")
        }
        Button { selection = .computer(hostID: host.id) } label: {
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
    private func entries(for host: HostConnection) -> [ProjectEntry] {
        let query = search.trimmed.lowercased()
        let hostMatches = query.isEmpty
            || host.config.name.lowercased().contains(query)
            || host.config.host.lowercased().contains(query)
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
            if case .computer(let hostID) = selection, let host = store.host(for: hostID) {
                ComputerSettingsView(host: host, forget: {
                    selection = nil
                    store.remove(host)
                })
                .id(hostID)
            } else if case .project(let hostID, let cwd) = selection, let host = store.host(for: hostID),
                      let project = host.projects.first(where: { $0.cwd == cwd }) {
                ProjectSettingsView(host: host, project: project,
                                    rename: { nameDraft = project.alias ?? ""; renamingProject = ProjectTarget(host: host, project: project) },
                                    locate: { troubled = ProjectTarget(host: host, project: project) },
                                    archive: { selection = .archived(hostID: hostID, cwd: cwd) },
                                    remove: { removingProject = ProjectTarget(host: host, project: project) })
                    .id(hostID + "|" + cwd + "|settings")
            } else if case .archived(let hostID, let cwd) = selection, let host = store.host(for: hostID) {
                ArchivedList(host: host, cwd: cwd)
                    .id(hostID + "|" + cwd)
            } else if let which = selection?.session, let host = store.host(for: which.hostID) {
                AgentScreen(host: host, sessionID: which.sessionID)
                    .id(which)
            } else {
                EmptyDetail(title: "Nothing selected",
                            subtitle: store.hosts.isEmpty ? "Connect a computer first." : "Pick a computer, a project or a session, or tap compose to start one.")
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

/// A project and the computer it runs on: what the sidebar lists.
struct ProjectEntry: Identifiable {
    let host: HostConnection
    let project: HostConnection.Project
    var id: String { host.id + "|" + project.cwd }
    var target: ProjectTarget { ProjectTarget(host: host, project: project) }
}

/// A session an alert is about.
struct SessionTarget: Identifiable {
    let host: HostConnection
    let session: SessionInfo
    var id: String { host.id + "|" + session.id }
}

/// A project an alert or a picker is about.
struct ProjectTarget: Identifiable {
    let host: HostConnection
    let project: HostConnection.Project
    var id: String { host.id + "|" + project.cwd }
    var cwd: String { project.cwd }
    var name: String { project.name }
    var sessionCount: Int { project.sessions.count + project.archived.count }
}

/// What the sidebar has selected: a computer, a project, a session, or a
/// project's archive.
public enum ContentSelection: Hashable {
    case computer(hostID: String)
    case project(hostID: String, cwd: String)
    case session(SessionSelection)
    /// A project's archive, by the computer and the folder it runs in.
    case archived(hostID: String, cwd: String)

    var session: SessionSelection? { if case .session(let value) = self { value } else { nil } }
    var hostID: String? {
        switch self {
        case .computer(let hostID): hostID
        case .project(let hostID, _): hostID
        case .session(let value): value.hostID
        case .archived(let hostID, _): hostID
        }
    }
}

/// Which session is open: a host and a session id, one value for the list's selection.
public struct SessionSelection: Hashable {
    public var hostID: String
    public var sessionID: String
}

/// A computer's section: observes the computer, so its rows and its
/// header follow the connection and the sessions as they change.
@MainActor
struct HostSection<Rows: View>: View {
    @ObservedObject var host: HostConnection
    @ViewBuilder let rows: (HostConnection) -> Rows

    var body: some View {
        Section {
            rows(host)
        } header: {
            HStack(spacing: 6) {
                Circle().fill(host.badge.color).frame(width: 8, height: 8)
                Text(host.config.name.isEmpty ? host.config.host : host.config.name)
                    .lineLimit(1)
                Spacer()
                // The dot says "connected"; words only for what it cannot
                // (offline and why, a password wanted, an error).
                if host.state != .connected {
                    Text(host.state.label)
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                }
            }
            .font(.subheadline)
            .noHeaderCase()
            .accessibilityIdentifier("computer-" + host.config.name)
        }
    }
}

/// One project's archive, in the detail column: its ended sessions. A
/// session comes back or goes for good; it is not read here.
@MainActor
struct ArchivedList: View {
    @ObservedObject var host: HostConnection
    let cwd: String
    @State private var deleting: SessionInfo?

    private var project: HostConnection.Project? { host.projects.first { $0.cwd == cwd } }

    var body: some View {
        List {
            if project?.archived.isEmpty ?? true {
                Text("Nothing archived in this project.").foregroundColor(.secondary).font(.footnote)
            }
            if let project {
                    ForEach(project.archived) { session in
                        ArchivedRow(session: session)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button { host.unarchive(session.id) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
                                    .tint(.green)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deleting = session } label: { Label("Remove", systemImage: "trash") }
                            }
                            .contextMenu {
                                Button { host.unarchive(session.id) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
                                if let command = session.resumeCommand {
                                    Button { copyToPasteboard(command) } label: { Label("Copy resume command", systemImage: "doc.on.doc") }
                                }
                                Button(role: .destructive) { deleting = session } label: { Label("Remove", systemImage: "trash") }
                            }
                    }
            }
        }
        .groupedRows()
        .navigationTitle("Archived Sessions")
        .toolbarTitleDisplayMode(.inline)
        .alert("Remove this session?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Remove", role: .destructive) {
                if let deleting { host.end(deleting.id) }
                deleting = nil
            }
        } message: {
            Text(VisorRootView.removeSessionExplanation(deleting))
        }
    }
}

/// An archived session under its project: the title, dimmed, with the
/// command that resumes the agent's own session beneath it.
@MainActor
struct ArchivedRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(spacing: OutlineMetrics.gap) {
            Image(systemName: "archivebox")
                .foregroundColor(.secondary)
                .frame(width: OutlineMetrics.glyph, height: OutlineMetrics.glyph)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? session.agent.title : session.title)
                    .lineLimit(1)
                if let command = session.resumeCommand {
                    Text(command)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

/// A session and where it runs: what a row of the sidebar shows.
struct SessionCard: Identifiable {
    let host: HostConnection
    let project: HostConnection.Project
    let session: SessionInfo
    var id: String { host.id + "|" + session.id }
    var updated: Double { session.updated ?? session.created }
}

/// A session in the sidebar: its name, its project, the first lines of
/// the latest message; and at the trailing edge what is happening — a
/// spinner while the agent works, a raised hand while it waits to be
/// allowed something. Whether the computer answers is its section's.
@MainActor
struct SessionCardRow: View {
    @ObservedObject var host: HostConnection
    let project: HostConnection.Project
    let session: SessionInfo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title.isEmpty ? session.agent.title : session.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(project.name)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(session.preview ?? "No messages yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if session.busy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Working")
            } else if session.pendingApproval != nil {
                Image(systemName: "hand.raised.fill").foregroundColor(.yellow)
                    .accessibilityLabel("Waiting for approval")
            }
        }
        .accessibilityIdentifier("session-" + session.id)
    }
}

extension HostConnection.Badge {
    /// Green answering, yellow not yet, red refused or never reached.
    var color: Color {
        switch self {
        case .connected: .green
        case .wasConnected: .yellow
        case .unreachable: .red
        }
    }
}

/// The sidebar's geometry, fixed: a row is inset 8pt, then a 16pt glyph
/// (the state dot or spinner, the archive box), 8pt, and the text. Rows
/// have 8pt above and below.
enum OutlineMetrics {
    static let glyph: CGFloat = 16
    static let gap: CGFloat = 8
}
