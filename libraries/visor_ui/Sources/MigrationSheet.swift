import AgentUI
import SwiftUI
import VisorClient
import VisorProtocol

/// Moving a session to another computer (SessionMigration), the computer
/// chosen from the session's menu: what the move carries (the agent's own
/// files for the conversation) and where the session runs there (a new,
/// empty folder that computer chooses), then the move with its progress.
/// No project comes: the agent clones what it needs there. The session it
/// came from is left as it was.
@MainActor
struct MigrationSheet: View {
    let migration: SessionMigration
    /// Opens the session where it moved.
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { content }
                .insetGroupedForm()
                .navigationTitle("Migrate “\(migration.session.title)”")
                .toolbarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .presentationDetentsLarge()
        .task { if migration.phase == .preparing { await migration.prepare() } }
    }

    @ViewBuilder private var content: some View {
        switch migration.phase {
        case .preparing:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Looking at the session on \(migration.from.record.name)…").foregroundStyle(.secondary)
                }
            }
        case .ready:
            plan
        case .moving:
            Section {
                ProgressView(value: migration.progress) { Text(migration.doing) }
            }
        case .done:
            Section {
                Label("Migrated to \(migration.to.record.name).", systemImage: "checkmark.circle.fill")
                Text("The session on \(migration.from.record.name) is as it was. Remove it once the one on \(migration.to.record.name) works.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let problem):
            Section {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var plan: some View {
        if let plan = migration.plan, let offer = migration.offer {
            Section {
                LabeledContent("From", value: migration.from.record.name)
                LabeledContent("To", value: migration.to.record.name)
                LabeledContent("Conversation", value: Self.size(offer.size))
                LabeledContent("Runs In", value: plan.cwd)
            } footer: {
                Text(footnote(agentInstalled: plan.agentInstalled))
            }
        }
    }

    /// What the move carries and leaves, and whether the agent is there.
    private func footnote(agentInstalled: Bool) -> String {
        let from = migration.from.record.name, to = migration.to.record.name
        var said = agentInstalled ? "" : "\(migration.session.agent.title) is not installed on \(to): install it there before the session can carry on. "
        said += "The agent's own files for the conversation come (Claude's memory too); projects don't: the session starts in a new, empty folder on \(to), "
            + "and its agent clones what it needs there. The session on \(from) stays as it is; remove it once the one on \(to) works."
        return said
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        switch migration.phase {
        case .done(let session):
            ToolbarItem(placement: .confirmationAction) {
                Button("Open") {
                    open(session)
                    dismiss()
                }
            }
        case .failed:
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Try Again") { Task { await migration.prepare() } } }
        case .moving:
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(true) }
        case .preparing, .ready:
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Migrate") { migration.start() }.disabled(migration.phase != .ready)
            }
        }
    }

    static func size(_ bytes: Int) -> String {
        guard bytes >= 1 << 20 else { return "\(max(1, bytes >> 10)) KB" }
        let (unit, shift) = bytes >= 1 << 30 ? ("GB", 30) : ("MB", 20)
        let tenths = (bytes * 10 + (1 << (shift - 1))) >> shift
        return "\(tenths / 10).\(tenths % 10) \(unit)"
    }
}
