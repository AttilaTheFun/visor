import AppKit
import SwiftUI
import VisorRunner

/// Settings' container servers (docs/co-tenancy.md): each one's state, its
/// code to copy, Stop or Start, and Remove; a new one made; and the
/// sign-ins their agents are given.
struct ContainerServersSection: View {
    var servers: RunnerContainerServers
    var defaultImage: String
    @State private var making = false
    @State private var removing: RunnerContainerServers.Row?
    @State private var claudeToken = ""
    @State private var openrouterKey = ""
    @State private var saved = false

    var body: some View {
        Section {
            if servers.rows.isEmpty {
                Text("A container server is a Visor server in a Linux container of its own, on this Mac: its sessions' agents, their files and the pictures you attach are all inside it. A client adds it from its code, as another computer.")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(servers.rows) { row in rowView(row) }
            Button("New Container Server…") { making = true }
            if let message = servers.message { Text(message).font(.caption).foregroundColor(.red) }
        } header: {
            Text("Container Servers")
        }
        .sheet(isPresented: $making) { NewContainerServerSheet(servers: servers, defaultImage: defaultImage) }
        .confirmationDialog("Remove \(removing?.spec.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { servers.remove(removing.id) }
                removing = nil
            }
        } message: {
            Text("Its container goes, and with it its sessions and their files. Folders of this Mac's that it saw are left as they are.")
        }
        Section {
            SecureField("Claude OAuth token", text: $claudeToken)
            SecureField("OpenRouter API key", text: $openrouterKey)
            HStack {
                Button("Save") {
                    servers.setSignIns(claudeToken: claudeToken, openrouterKey: openrouterKey)
                    saved = true
                }
                .disabled(claudeToken == servers.claudeToken && openrouterKey == servers.openrouterKey)
                if saved { Text("Given to every container server.").font(.caption).foregroundColor(.secondary) }
            }
            Text("Each container server's agents sign in with these (`claude setup-token` makes a Claude token). Codex signs in with this Mac's own sign-in, copied in. Sessions on this Mac's server sign in as they always do.")
                .font(.caption).foregroundColor(.secondary)
        } header: {
            Text("Container Sign-ins")
        }
        .onAppear {
            claudeToken = servers.claudeToken
            openrouterKey = servers.openrouterKey
            servers.reload()
        }
    }

    private func rowView(_ row: RunnerContainerServers.Row) -> some View {
        let busy = servers.busy.contains(row.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.spec.name).bold()
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Text(Self.status(row)).font(.caption).foregroundColor(.secondary)
            }
            if let address = row.state?.address {
                Text(address).font(.caption.monospaced()).textSelection(.enabled)
            }
            if row.state?.state == "failed", let error = row.state?.error {
                Text(error).font(.caption).foregroundColor(.red)
            }
            HStack {
                if let code = row.state?.code {
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                }
                if row.stopped {
                    Button("Start") { servers.start(row.id) }
                } else {
                    Button("Stop") { servers.stop(row.id) }
                }
                Button("Remove…", role: .destructive) { removing = row }
            }
            .disabled(busy)
        }
    }

    /// A server's state in a word or two.
    static func status(_ row: RunnerContainerServers.Row) -> String {
        if row.stopped { return "Stopped" }
        switch row.state?.state {
        case "ready": return row.state?.server?.version.map { "Ready, \($0)" } ?? "Ready"
        case "failed": return "Failed"
        // Its container not made yet, or not yet started again.
        default: return "Starting…"
        }
    }
}
