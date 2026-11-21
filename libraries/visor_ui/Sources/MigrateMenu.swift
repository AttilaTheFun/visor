import SwiftUI
import VisorClient
import VisorProtocol

/// A session's Migrate… (docs/containers.md, "Placing sessions"): the
/// places it can be, the one it's in ticked. On its own computer (`‹name›`)
/// or in that computer's Sessions container (`‹name›'s Container`), moved
/// between the two on the server (Move to Container, Move Back, its
/// conversation carried both ways); or another computer connected now that
/// migrates, which opens the Migrate sheet (this one keeps the session
/// until the user removes it). Shown when there is somewhere to go.
@MainActor
struct MigrateMenu: View {
    let session: SessionInfo
    let host: AgentServerConnection
    /// The other computers connected now that take migrations.
    let others: [AgentServerConnection]
    /// A move to another computer, chosen: the Migrate sheet's.
    let migrate: (AgentServerConnection) -> Void

    /// Where it is on its computer: there, unless placed elsewhere.
    private var placement: SessionPlacement { session.placement ?? .host }
    private var name: String { host.record.name.isEmpty ? host.record.address : host.record.name }
    /// Into the container: a Claude Code session on the computer itself,
    /// while its container takes sessions.
    private var intoContainer: Bool { placement == .host && session.agent == .claude && !session.archived && host.takesContainerSessions }
    /// Back from the container, or a runner.
    private var back: Bool { placement != .host }
    private var elsewhere: [AgentServerConnection] { host.migrates ? others : [] }

    /// Whether there is anywhere to go.
    static func offers(_ session: SessionInfo, host: AgentServerConnection, others: [AgentServerConnection]) -> Bool {
        let menu = MigrateMenu(session: session, host: host, others: others) { _ in }
        return menu.intoContainer || menu.back || !menu.elsewhere.isEmpty
    }

    var body: some View {
        if Self.offers(session, host: host, others: others) {
            Menu {
                Button { host.moveBack(session.id) } label: { place(name, here: placement == .host, image: "desktopcomputer") }
                    .disabled(!back)
                    .accessibilityIdentifier("migrate-host")
                if intoContainer || placement == .container {
                    Button { host.moveToContainer(session.id) } label: {
                        place("\(name)'s Container", here: placement == .container, image: "shippingbox")
                    }
                    .disabled(!intoContainer)
                    .accessibilityIdentifier("migrate-container")
                }
                if !elsewhere.isEmpty {
                    Divider()
                    ForEach(elsewhere, id: \.id) { other in
                        Button(other.record.name) { migrate(other) }
                    }
                }
            } label: {
                Label("Migrate…", systemImage: "arrow.right.circle")
            }
        }
    }

    /// A place, ticked where the session is.
    private func place(_ title: String, here: Bool, image: String) -> some View {
        Label(title, systemImage: here ? "checkmark" : image)
    }
}
