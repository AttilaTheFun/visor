// The one compose, beside the search: everything a session needs before it
// exists — which computer, which folder, which harness, and what to call
// it. The folder is picked from the computer's projects or browsed for.
// Sessions start in auto mode (no permission prompts — nobody is at the
// computer to answer them); the chat's permissions pill switches to manual.

import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct ComposeSessionSheet: View {
    @ObservedObject var store: VisorStore
    /// The computer and the new session's id.
    let started: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hostID = ""
    @State private var cwd = ""
    @State private var agent: AgentKind = .claude
    @State private var title = ""
    @State private var browsing = false
    @State private var resuming = false
    @State private var resumable: [ResumableSession] = []
    @State private var loadingResumable = false
    @State private var resumeID = ""

    /// Only a computer that is answering can start a session.
    private var host: HostConnection? {
        store.connectedHosts.first { $0.id == hostID } ?? store.connectedHosts.first
    }
    private var available: Set<AgentKind> {
        Set((host?.catalogs ?? []).filter(\.available).map(\.agent))
    }
    private var ready: Bool {
        host != nil && !cwd.trimmed.isEmpty && !(resuming && resumeID.trimmed.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Where") {
                    if store.connectedHosts.isEmpty {
                        Text("No computer is connected. Sessions start on a computer that is answering; check Computers.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Picker("Computer", selection: $hostID) {
                        ForEach(store.connectedHosts) { host in
                            Text(host.config.name.isEmpty ? host.config.host : host.config.name).tag(host.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("computer")
                    if let host {
                        // One row: the folder's path, which opens the
                        // folder browser.
                        Button { browsing = true } label: {
                            HStack {
                                Text("Project")
                                Spacer(minLength: 12)
                                Text(cwd.trimmed.isEmpty ? "~" : cwd)
                                    .font(.callout.monospaced())
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("project")
                    }
                }
                Section("Harness") {
                    Picker("Agent", selection: $agent) {
                        ForEach(AgentKind.allCases, id: \.self) { kind in
                            Text(available.contains(kind) || (host?.catalogs.isEmpty ?? true) ? kind.title : "\(kind.title) (not installed)").tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Conversation", selection: $resuming) {
                        Text("New").tag(false)
                        Text("Resume").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if resuming {
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
                    TextField(defaultTitle, text: $title)
                        .accessibilityIdentifier("title")
                } header: {
                    Text("Name")
                } footer: {
                    Text("Optional.")
                }

            }
            .navigationTitle("New Session")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: start)
                        .disabled(!ready)
                        .accessibilityIdentifier("start")
                }
            }
        }
        .presentationDetentsMediumLarge()
        .sheet(isPresented: $browsing) {
            if let host {
                FolderPicker(host: host, start: cwd) { chosen in
                    host.addProject(chosen)
                    cwd = chosen
                }
            }
        }
        .onAppear {
            if host?.id != hostID { hostID = store.connectedHosts.first?.id ?? "" }
            if cwd.isEmpty { useHome() }
            if !available.contains(agent), let first = AgentKind.allCases.first(where: available.contains) { agent = first }
        }
        .onChange(of: hostID) { _ in
            useHome()
            resumable = []
        }
        .onChange(of: resuming) { value in if value { loadResumable() } }
        .onChange(of: agent) { _ in if resuming { loadResumable() } }
        .onChange(of: cwd) { _ in if resuming { loadResumable() } }
    }

    private var defaultTitle: String {
        let siblings = host?.projects.first { $0.cwd == cwd }?.sessions.filter { $0.agent == agent }.count ?? 0
        return "\(agent.title) \(siblings + 1)"
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

    private func folderName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if trimmed == "~" || trimmed.isEmpty { return "Home" }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private func loadResumable() {
        guard let host, !cwd.trimmed.isEmpty else { return }
        loadingResumable = true
        Task {
            resumable = (try? await host.resumable(agent: agent, cwd: cwd)) ?? []
            loadingResumable = false
        }
    }

    private func start() {
        guard let host else { return }
        host.addProject(cwd)
        let id = host.start(agent: agent, cwd: cwd, title: title.trimmed, skipPermissions: true,
                            resume: resuming ? resumeID.trimmed : nil)
        dismiss()
        started(host.id, id)
    }
}
