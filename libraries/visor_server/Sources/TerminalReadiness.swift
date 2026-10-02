import ClaudeTranscript
import Darwin
import Foundation
import Synchronization
import VisorProtocol

/// Whether a terminal's agent is at its input box, told from what it
/// draws. Kept by whoever reads the terminal, off the main actor.
struct TerminalReadiness {
    let agent: AgentKind
    /// The last stretch of what the terminal showed, as text.
    private var recent = ""
    private(set) var ready = false

    init(agent: AgentKind) { self.agent = agent }

    /// Claude Code's screen says where it is: its input box comes with
    /// "? for shortcuts" (and the mode line's "shift+tab to cycle", or
    /// "esc to interrupt" while it works); a prompt to be answered — trust
    /// this folder, accept bypass mode, allow this tool — ends with "Enter
    /// to confirm · Esc to cancel". What the chat sends is typed only at
    /// the input box, never into a prompt.
    mutating func observe(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        recent = String((recent + text).suffix(6000))
        let stripped = recent.replacingOccurrences(of: "\u{1B}\\[[0-9;?<>=]*[A-Za-z]", with: "", options: .regularExpression)
        let promptAt = max(stripped.range(of: "to confirm", options: .backwards)?.lowerBound.utf16Offset(in: stripped) ?? -1,
                           stripped.range(of: "Esc to cancel", options: .backwards)?.lowerBound.utf16Offset(in: stripped) ?? -1)
        let boxAt = ["for shortcuts", "shift+tab to cycle", "esc to interrupt"].map {
            stripped.range(of: $0, options: .backwards)?.lowerBound.utf16Offset(in: stripped) ?? -1
        }.max() ?? -1
        // The openrouter CLI's input box is its "›" prompt.
        ready = agent == .openrouter ? stripped.hasSuffix("› ") : boxAt > promptAt
    }
}
