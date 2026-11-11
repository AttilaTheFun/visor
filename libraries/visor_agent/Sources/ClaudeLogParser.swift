import ClaudeTranscript
import Foundation
import VisorProtocol

/// Claude Code's own session file: already a tree of lines.
final class ClaudeLogParser: AgentLogParser {
    func lines(in data: Data) -> [ClaudeLine] { ClaudeTranscriptParser.lines(in: data) }
    func resume(after key: String?) {}
}
