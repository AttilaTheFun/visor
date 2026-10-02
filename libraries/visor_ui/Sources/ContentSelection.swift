import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// What the sidebar has selected: a computer, a project, a session, or a
/// project's archive.
public enum ContentSelection: Hashable {
    case computer(hostID: String)
    case project(hostID: String, cwd: String)
    case session(SessionSelection)
    /// A project's archive, by the computer and the folder it runs in.
    case archived(hostID: String, cwd: String)
    /// Everything archived on a computer, whichever folder it ran in.
    case hostArchive(hostID: String)

    var session: SessionSelection? { if case .session(let value) = self { value } else { nil } }
    var hostID: String? {
        switch self {
        case .computer(let hostID): hostID
        case .project(let hostID, _): hostID
        case .session(let value): value.hostID
        case .archived(let hostID, _): hostID
        case .hostArchive(let hostID): hostID
        }
    }
}
