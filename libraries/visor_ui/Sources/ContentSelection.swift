import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// What the sidebar has selected: a computer, a project, a session, or a
/// project's archive.
public enum ContentSelection: Hashable {
    case computer(serverID: String)
    case project(serverID: String, cwd: String)
    case session(SessionSelection)
    /// A project's archive, by the computer and the folder it runs in.
    case archived(serverID: String, cwd: String)
    /// Everything archived on a computer, whichever folder it ran in.
    case hostArchive(serverID: String)

    var session: SessionSelection? { if case .session(let value) = self { value } else { nil } }
    var serverID: String? {
        switch self {
        case .computer(let serverID): serverID
        case .project(let serverID, _): serverID
        case .session(let value): value.serverID
        case .archived(let serverID, _): serverID
        case .hostArchive(let serverID): serverID
        }
    }
}
