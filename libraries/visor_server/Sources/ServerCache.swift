import ClaudeTranscript
import MessageCache
import Foundation
import VisorProtocol

/// The server's message cache: every session's rows, from the agents' own
/// files where they have one and from their events where they do not.
/// Tests point `shared` at a cache of their own.
@MainActor
public enum ServerCache {
    public static var shared: MessageCache = .open(named: "messages")
}
