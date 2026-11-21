import VisorClient
import VisorProtocol

/// Where a session can go from Migrate… (docs/containers.md, "Placing
/// sessions"): its own computer, or that computer's Sessions container,
/// moved between on the server (Move Back, Move to Container: its
/// conversation carried both ways); or another computer connected now
/// that migrates (the Migrate sheet: this one keeps the session until the
/// user removes it). Each but the place it's in, while there is somewhere
/// to go. A plain button and an alert, which every client's SwiftUI draws
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
    var name: String { host.record.name.isEmpty ? host.record.address : host.record.name }
    /// The container's place, as offered.
    var containerName: String { "\(name)'s Container" }
    /// Into the container: a Claude Code session on the computer itself,
    /// while its container takes sessions.
    var intoContainer: Bool { placement == .host && session.agent == .claude && !session.archived && host.takesContainerSessions }
    /// Back onto the computer, from the container or a runner.
    var back: Bool { placement != .host }
    /// Other computers, where it can migrate.
    var elsewhere: [AgentServerConnection] { host.migrates ? others : [] }
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
}
