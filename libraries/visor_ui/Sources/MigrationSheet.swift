import AgentUI
import SwiftUI
import VisorClient
import VisorProtocol

/// Moving a session to another computer (SessionMigration): what the move
/// will do there — where the session runs, and for each project whether it
/// is there already, is cloned, copied or made — the projects to bring
/// chosen, then the move with its progress. The session it came from is
/// left as it was.
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
                LabeledContent("Folder", value: plan.cwd)
                LabeledContent("Conversation", value: Self.size(offer.size))
            } footer: {
                if !plan.agentInstalled {
                    Text("\(migration.session.agent.title) is not installed on \(migration.to.record.name): install it there before the session can carry on.")
                }
            }
            Section {
                ForEach(migration.steps.indices, id: \.self) { index in
                    let step = migration.steps[index]
                    if migration.isOptional(step) {
                        Toggle(isOn: Binding(get: { migration.steps[index].chosen }, set: { migration.steps[index].chosen = $0 })) { row(step) }
                    } else {
                        row(step)
                    }
                }
            } header: {
                Text("Projects")
            } footer: {
                Text("The session on \(migration.from.record.name) stays as it is; remove it once the one on \(migration.to.record.name) works.")
            }
        }
    }

    private func row(_ step: MigrationStep) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SessionMigration.name(of: step))
            Text(step.note).font(.caption).foregroundStyle(.secondary)
        }
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
