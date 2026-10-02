import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// A project an alert or a picker is about.
struct ProjectTarget: Identifiable {
    let host: HostConnection
    let project: HostConnection.Project
    var id: String { host.id + "|" + project.cwd }
    var cwd: String { project.cwd }
    var name: String { project.name }
    var sessionCount: Int { project.sessions.count + project.archived.count }
}
