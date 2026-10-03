import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

extension AgentServerConnection.Badge {
    /// Green answering, yellow not yet, red refused or never reached.
    var color: Color {
        switch self {
        case .connected: .green
        case .wasConnected: .yellow
        case .unreachable: .red
        }
    }
}
