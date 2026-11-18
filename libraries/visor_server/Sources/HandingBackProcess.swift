// A driven session's process that can hand its session back (agent_protocol's
// DriverMessage.hand_back): its wrapper said protocol 2 or more in its hello,
// so, asked to, it ends its agent as a stop does and then returns the
// conversation (AgentDriver.ReturnConversation) instead of leaving it where
// it ran. VisorDriver's DrivenProcess; moveBack asks it (VisorServer+HandBack).

import VisorAgent

@MainActor
package protocol HandingBackProcess: AgentProcess {
    /// Whether its wrapper takes a hand-back: its latest hello said
    /// protocol 2 or more.
    var takesHandBack: Bool { get }
    /// Its agent ended and its conversation returned: `hand_back` down to its
    /// wrapper, or held for the wrapper's next connection.
    func handBack()
}
