import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// Which session is open: a host and a session id, one value for the list's selection.
public struct SessionSelection: Hashable {
    public var hostID: String
    public var sessionID: String
}
