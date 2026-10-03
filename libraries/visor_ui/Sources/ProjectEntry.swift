import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// A project and the computer it runs on: what the sidebar lists.
struct ProjectEntry: Identifiable {
    let host: AgentServerConnection
    let project: AgentServerConnection.Project
    var id: String { host.id + "|" + project.cwd }
}
