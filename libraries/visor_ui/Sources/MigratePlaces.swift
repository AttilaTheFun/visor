import VisorClient
import VisorProtocol

/// Where a session can go from Migrate… (docs/containers.md, "Placing
/// sessions"): its own computer, or that computer's Sessions container,
/// moved between on the server (Move Back, Move to Container: its
/// conversation carried both ways); or another computer connected now
/// that migrates (the Migrate sheet: this one keeps the session until the
/// user removes it). Each but the place it's in, while there is somewhere
/// to go. Another computer is shown but not offered for a session in the
/// container, which moves back first: a migration reads this computer's
/// Claude folder, and its turns there would be left behind (the server
/// refuses it too). A plain button and an alert, which every client's SwiftUI draws
/// (a menu within a context menu is Apple's alone).
@MainActor
struct MigratePlaces {
    let session: SessionInfo
    let host: AgentServerConnection
    /// The other computers connected now that take migrations.
    let others: [AgentServerConnection]

    /// Where it is on its computer: there, unless placed elsewhere.
    var placement: SessionPlacement { session.placement ?? .host }
    /// Its computer's name.
    var name: String { Self.name(of: host) }
    /// The container's place, as offered.
    var containerName: String { Self.containerName(of: host) }

    /// A computer's name, as its places are offered (here and in New
    /// Session).
    static func name(of host: AgentServerConnection) -> String {
        host.record.name.isEmpty ? host.record.address : host.record.name
    }
    /// A computer's Sessions container, as a place it's offered.
    static func containerName(of host: AgentServerConnection) -> String { "\(name(of: host))'s Container" }
    /// Into the container: a Claude Code session on the computer itself,
    /// while its container takes sessions.
    var intoContainer: Bool { placement == .host && session.agent == .claude && !session.archived && host.takesContainerSessions }
    /// Back onto the computer, from the container or a runner.
    var back: Bool { placement != .host }
    /// Other computers, where it can migrate (or could, once it's back).
    var elsewhere: [AgentServerConnection] { host.migrates ? others : [] }
    /// Whether the other computers wait for it to move back first.
    var elsewhereWaits: Bool { placement == .container }
    /// Whether there is anywhere to go.
    var offers: Bool { intoContainer || back || !elsewhere.isEmpty }

    /// Where it is now, said.
    var here: String {
        switch placement {
        case .container: "It's in \(containerName)."
        case .runner: "It's on a runner of \(name)'s."
        case .host: "It's on \(name)."
        }
    }

    /// What Migrate… says: where it is, and, for one in the container with
    /// other computers to go to, that it moves back first.
    var said: String {
        guard elsewhereWaits, !elsewhere.isEmpty else { return here }
        return here + " Move it back to \(name) first to migrate it to another computer, so its conversation there comes with it."
    }
}
