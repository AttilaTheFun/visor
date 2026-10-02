import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// A session and where it runs: what a row of the sidebar shows.
struct SessionCard: Identifiable {
    let host: HostConnection
    let project: HostConnection.Project
    let session: SessionInfo
    var id: String { host.id + "|" + session.id }
    var updated: Double { session.updated ?? session.created }
}
