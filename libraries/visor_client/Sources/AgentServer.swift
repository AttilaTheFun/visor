// An agent server is somewhere agents run and a client manages them: a Mac
// running the menu bar app, reached over Tailscale, is the one shipped; a
// company's service hosting remote agents is one a fork adds. Everything
// the client asks of a server goes through this protocol — signing in,
// the live channel, and each one-shot operation — so a different server
// is a different conformance, and nothing above it changes. The Tailscale
// one speaks the wire protocol (docs/protocol.md); a fork's speaks whatever
// its service speaks, and hands back the same values.

import VisorProtocol
import VisorServices

@MainActor
public protocol AgentServer: AnyObject {
    // MARK: Signing in and the live channel

    /// Signs in with the record's credentials, before the channel opens:
    /// the server's own name, if it gives one. Throws
    /// `AgentServerError.needsAuthentication` when the credentials are
    /// missing or refused, which the connection shows and does not retry.
    func authenticate(_ record: AgentServerRecord) async throws -> String?
    /// Opens the live channel after a sign-in. What the server says comes
    /// back through `onEvent`, starting with `.welcome`; `.closed` ends it
    /// (the connection reopens it after a while).
    func openChannel(onEvent: @escaping @MainActor (AgentServerEvent) -> Void)
    func closeChannel()
    /// A pause, for the reconnect backoff: the host's timer, which is
    /// portable where `Task.sleep` is not.
    func delay(milliseconds: Int32) async

    // MARK: Over the live channel

    /// Follows a session: its state and new rows arrive as `.session` events.
    func subscribe(_ session: String)
    /// Takes the session into the agent's own terminal, drawn for a window
    /// of this size on this client.
    func assumeControl(_ session: String, cols: Int, rows: Int)
    /// Hands the session back to the chat.
    func returnToChat(_ session: String)
    /// The user has read what the session had to tell them.
    func acknowledge(_ session: String)
    /// Asks for the rows before `before`.
    func loadEarlier(_ session: String, before: String)
    /// What the user typed into the terminal, base64.
    func sendInput(_ session: String, data: String)
    func resize(_ session: String, cols: Int, rows: Int)

    // MARK: Sessions

    /// The server's sessions now, asked for outright rather than heard
    /// over the channel: the connection asks every minute, as the backup
    /// for a channel that has gone quiet or cannot be opened.
    func sessions() async throws -> [SessionInfo]
    /// Starts a session with the id the client chose. The sessions the
    /// answer names are taken into the list.
    func startSession(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool, resume: String?) async throws -> [SessionInfo]
    /// One command on a session; the sessions the answer names are taken
    /// into the list (after `.end`, they replace it).
    func act(_ action: SessionAction, on session: String) async throws -> [SessionInfo]
    /// A message from the user, with the paths of any pictures already
    /// uploaded. Sent to a working agent, it waits in the session's queue.
    func sendMessage(_ session: String, text: String, images: [String]) async throws -> [SessionInfo]
    /// The session's rows past `revision` in `generation`, as a transcript
    /// envelope; the server holds the answer until the rows have moved
    /// (or for a while, then answers with the same).
    func transcript(of session: String, since revision: Int, generation: Int) async throws -> Envelope
    /// The slash commands the session's agent takes.
    func commands(for session: String) async throws -> [SlashCommand]
    /// The agent's own sessions started in `cwd`, newest first.
    func resumable(agent: AgentKind, cwd: String) async throws -> [ResumableSession]
    /// The sessions that ran in a folder follow it to where it moved.
    func relocateSessions(from cwd: String, to destination: String) async throws -> [SessionInfo]

    // MARK: Folders and files

    func folders(at path: String) async throws -> FolderListing
    /// Creates the folder (and its parents); where it landed.
    func makeFolder(_ path: String) async throws -> String
    /// The bytes of a picture the server holds, base64.
    func fileData(path: String) async throws -> String
    /// Puts a picture or a video on the server; where it landed, which is
    /// what the agent is then pointed at.
    func upload(base64: String, name: String) async throws -> String
    /// The messages whose words match, across every session, best first.
    func search(_ query: String) async throws -> [SearchHit]

    // MARK: Where the server has them

    /// Gives the server this device's push token. Whether the server sends
    /// pushes: then it says what happened, and the device does not say it
    /// too. A server without pushes answers false.
    func registerPush(token: String, platform: String, environment: String, topic: String) async throws -> Bool
    /// The server's connection code, for linking servers to one another.
    func connectionCode() async throws -> String
    /// Links another server to this one by its code, so the agents here
    /// reach the sessions there.
    func link(code: String) async throws
}

public extension AgentServer {
    func registerPush(token: String, platform: String, environment: String, topic: String) async throws -> Bool { false }
    func connectionCode() async throws -> String { throw AgentServerError.unsupported }
    func link(code: String) async throws { throw AgentServerError.unsupported }
}
