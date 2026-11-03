// A computer's session backups (`/api/backups`): Back Up Sessions keeps
// every session's conversation in a folder on the computer, and each backup
// kept there restores what the computer no longer has — for an update that
// might lose sessions. Each is one half of moving a session to another
// computer, with the folder in between.

import Foundation
import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct BackupSection: View {
    var host: AgentServerConnection
    /// The backups kept on the computer, newest first, once asked for.
    @State private var backups: [SessionBackup] = []
    @State private var working = false
    /// What the last backup or restore came to, or why it didn't.
    @State private var said: String?
    /// The backup a restore was asked of, until it is confirmed.
    @State private var restoring: SessionBackup?

    var body: some View {
        Section {
            Button(working ? "Working…" : "Back Up Sessions", action: backUp)
                .disabled(working)
                .accessibilityIdentifier("back-up-sessions")
            ForEach(backups, id: \.path) { backup in
                Button { restoring = backup } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restore \(Self.name(of: backup))")
                        Text(Self.detail(of: backup, now: Date().timeIntervalSince1970))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(working)
            }
            if let said { Text(said).font(.footnote) }
        } header: {
            Text("Session backups")
        } footer: {
            Text("Back Up Sessions keeps every session's conversation in a folder on this computer, for an update that might lose sessions. Restoring puts back what the computer no longer has: a session that is gone starts again on the same conversation, and one that has gone on since is left as it is. Projects stay where they are.")
        }
        .task { await load() }
        .alert("Restore these sessions?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("Cancel", role: .cancel) { restoring = nil }
            Button("Restore") {
                if let restoring { restore(restoring) }
                restoring = nil
            }
        } message: {
            Text("What the backup holds and this computer no longer has is put back. Nothing here is removed: a shorter conversation is set aside beside the one restored.")
        }
    }

    /// The backup's folder's name: when it was made ("20261103-013108").
    static func name(of backup: SessionBackup) -> String {
        backup.path.split(separator: "/").last.map(String.init) ?? backup.path
    }

    /// "4 sessions, 12.5 MB, 2 hr ago".
    static func detail(of backup: SessionBackup, now: Double) -> String {
        let count = backup.sessions.filter(\.kept).count
        return "\(count) session\(count == 1 ? "" : "s"), \(megabytes(backup.size)), \(UsageWords.ago(now - backup.created))"
    }

    /// "340 KB", "12.5 MB", "1.3 GB".
    static func megabytes(_ bytes: Int) -> String {
        guard bytes >= 1 << 20 else { return "\(max(1, bytes >> 10)) KB" }
        let (unit, shift) = bytes >= 1 << 30 ? ("GB", 30) : ("MB", 20)
        let tenths = (bytes * 10 + (1 << (shift - 1))) >> shift
        return "\(tenths / 10).\(tenths % 10) \(unit)"
    }

    /// What a backup or a restore came to, in a line: the sessions it did,
    /// and each one it didn't, with why.
    static func summary(of backup: SessionBackup, restoring: Bool) -> String {
        let done = backup.sessions.filter { restoring ? $0.outcome.hasPrefix("Restored") : $0.kept }
        let rest = backup.sessions.filter { restoring ? !$0.outcome.hasPrefix("Restored") : !$0.kept }
        var line = restoring ? "Restored \(done.count) of \(backup.sessions.count)." : "Backed up \(done.count) of \(backup.sessions.count) to \(backup.path)."
        for item in rest { line += " \(item.title.isEmpty ? item.id : item.title): \(item.outcome)" }
        return line
    }

    private func load() async {
        guard host.backsUp, let kept = try? await host.sessionBackups() else { return }
        backups = kept
    }

    private func backUp() {
        working = true
        said = nil
        Task {
            do {
                let backup = try await host.backUpSessions()
                said = Self.summary(of: backup, restoring: false)
            } catch {
                said = "Not backed up: \(error)"
            }
            await load()
            working = false
        }
    }

    private func restore(_ backup: SessionBackup) {
        working = true
        said = nil
        Task {
            do {
                let restored = try await host.restoreSessions(from: backup.path)
                said = Self.summary(of: restored, restoring: true)
            } catch {
                said = "Not restored: \(error)"
            }
            working = false
        }
    }
}
