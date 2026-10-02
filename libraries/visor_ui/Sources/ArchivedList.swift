import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// An archive in the detail column: a computer's ended sessions, newest
/// first, or one project's. A session comes back or goes for good; it is
/// not read here.
@MainActor
struct ArchivedList: View {
    @ObservedObject var host: HostConnection
    /// One project's folder, or nil for everything on the computer.
    let cwd: String?
    let openProject: (String) -> Void
    @State private var deleting: SessionInfo?

    var body: some View {
        // Worked out once per change of the computer's sessions.
        let sessions = host.archivedSessions
            .filter { cwd == nil || $0.cwd == cwd }
            .sorted { ($0.updated ?? $0.created) > ($1.updated ?? $1.created) }
        List {
            if sessions.isEmpty {
                Text(cwd == nil ? "Nothing archived on this computer." : "Nothing archived in this project.")
                    .foregroundColor(.secondary).font(.footnote)
            }
            ForEach(sessions) { session in
                ArchivedRow(session: session)
                    .accessibilityIdentifier("archived-session-" + session.id)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { host.unarchive(session.id) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
                            .tint(.green)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // An ordinary button tinted red, not the destructive
                        // role: that role readies SwiftUI's row-removal
                        // animation as the action appears, which stalled the
                        // swipe on a phone. The alert asks before anything
                        // is removed either way.
                        Button { deleting = session } label: { Label("Remove", systemImage: "trash") }
                            .tint(.red)
                    }
                    .contextMenu {
                        Button { host.unarchive(session.id) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
                        if let command = session.resumeCommand {
                            Button { copyToPasteboard(command) } label: { Label("Copy resume command", systemImage: "doc.on.doc") }
                        }
                        Button { openProject(session.cwd) } label: { Label("Project Settings", systemImage: "folder") }
                        Button(role: .destructive) { deleting = session } label: { Label("Remove", systemImage: "trash") }
                    }
            }
        }
        // The sidebar's own list style, whose swipes are smooth.
        .insetGroupedList()
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
