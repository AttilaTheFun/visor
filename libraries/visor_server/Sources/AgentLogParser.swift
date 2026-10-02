import ClaudeTranscript
import Foundation
import VisorProtocol

/// Reads a log's whole lines into lines of Claude's shape. Stateful: a log
/// that is a plain list links each line to the one before, across reads.
/// One parser reads one log, and belongs to whoever reads it.
protocol AgentLogParser: AnyObject {
    func lines(in data: Data) -> [ClaudeLine]
    /// The last line already read (from the cache), when reading resumes
    /// part-way through the log.
    func resume(after key: String?)
}
