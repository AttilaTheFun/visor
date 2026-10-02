import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// A session an alert is about.
struct SessionTarget: Identifiable {
    let host: HostConnection
    let session: SessionInfo
    var id: String { host.id + "|" + session.id }
}
