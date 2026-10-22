// An agent server is somewhere agents run and a client manages them: a
// computer running Visor Server, reached at whatever address it has, is
// the one shipped; a company's service hosting remote agents is one a
// fork adds. Everything the client asks of a server goes through this
// protocol — signing in, the live channel, and each one-shot operation —
// so a different server is a different conformance, and nothing above it
// changes. The one shipped speaks the wire protocol (docs/protocol.md); a
// fork's speaks whatever its service speaks, and hands back the same
// values.

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
    /// Whether the server signs in by several paths at once
    /// (`authenticate(_:byFirstOf:headStarts:timeouts:)`). One that does not
    /// is signed in by one path at a time, the next tried when one fails.
    var racesPaths: Bool { get }
    /// Signs in by whichever of `paths` answers first (the record's
    /// address aside): the first tried at once, each next one when the
    /// one before has had its `headStarts` entry alone, or at once when
    /// every one before it has failed, each given its `timeouts` entry. The server's name and the
    /// path that answered. `needsAuthentication` only when no path got in
    /// and one was refused for want of credentials.
    func authenticate(_ record: AgentServerRecord, byFirstOf paths: [String], headStarts: [Int32],
                      timeouts: [Int32]) async throws -> (name: String?, path: String)
    /// Opens the live channel after a sign-in. What the server says comes
    /// back through `onEvent`, starting with `.welcome`; `.closed` ends it
    /// (the connection reopens it after a while).
    func openChannel(onEvent: @escaping @MainActor (AgentServerEvent) -> Void)
    func closeChannel()
    /// Asks the open channel whether it is still there, now rather than
    /// at its next heartbeat: false when it does not answer in a moment.
    /// Asked when the app comes back to the front, where a channel that
    /// looks open may have died while the app was not running.
    func verifyChannel() async -> Bool
    /// A pause, for the reconnect backoff: the host's timer, which is
    /// portable where `Task.sleep` is not.
    func delay(milliseconds: Int32) async

    // MARK: Over the live channel

    /// Follows a session: its state and new rows arrive as `.session` events.
    func subscribe(_ session: String)
    /// Stops following a session that was left.
    func unsubscribe(_ session: String)
    /// The code a sign-in page showed, for the session's sign-in (`/login`).
    func signIn(_ session: String, code: String)
    /// The user has read what the session had to tell them.
    func acknowledge(_ session: String)
    /// Asks for the rows before `before`.
    func loadEarlier(_ session: String, before: String)

    // MARK: Sessions

    /// The server's sessions now, asked for outright rather than heard
    /// over the channel: the connection asks every minute, as the backup
    /// for a channel that has gone quiet or cannot be opened.
    func sessions() async throws -> [SessionInfo]
    /// Starts a session with the id the client chose. The sessions the
    /// answer names are taken into the list.
    func startSession(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool, resume: String?) async throws -> [SessionInfo]
    /// Starts a session whose agent runs in a container on the server's
    /// oss, `repository` (owner/name) cloned into it; answered once the
    /// container is made.
    func startSessionInContainer(id: String, agent: AgentKind, title: String, skipPermissions: Bool, repository: String?) async throws -> [SessionInfo]
    /// One command on a session; the sessions the answer names are taken
    /// into the list (after `.end`, they replace it).
    func act(_ action: SessionAction, on session: String) async throws -> [SessionInfo]
    /// A message from the user, with the paths of any pictures already
    /// uploaded. Sent to a working agent, it waits in the session's queue.
    func sendMessage(_ session: String, text: String, images: [String]) async throws -> [SessionInfo]
    /// The session's rows past `revision` in `generation`, as a transcript
    /// envelope; the server holds the answer until the rows have moved
    /// (or for a while, then answers with the same). With `after`, a
    /// client catching up asks for the next page of those rows, the ones
    /// after that row (answered at once; `later` says more follow).
    func transcript(of session: String, since revision: Int, generation: Int, after: String?) async throws -> Envelope
    /// The slash commands the session's agent takes.
    func commands(for session: String) async throws -> [SlashCommand]
    /// How an agent's account stands now: read afresh where the server
    /// can ask the agent, what it last heard where it cannot. Nil from a
    /// server that does not say.
    func account(of agent: AgentKind) async throws -> AgentAccount?
    /// The agent's own sessions started in `cwd`, newest first.
    func resumable(agent: AgentKind, cwd: String) async throws -> [ResumableSession]
    /// The sessions that ran in a folder follow it to where it moved.
    func relocateSessions(from cwd: String, to destination: String) async throws -> [SessionInfo]

    // MARK: New sessions, where the server sets them up its own way

    /// How a new session is set up here: in a folder (a computer's), or
    /// from the server's own choices, and whether only with its first
    /// message.
    var starting: SessionStarting { get }
    /// The named choices a new session starts from, when
    /// `starting.fromChoices`.
    func startChoices() async throws -> [StartChoice]
    /// Starts a session with its first message, for a server whose
    /// sessions start only with one (`starting.withFirstMessage`): the
    /// session started, whose id may be the server's own rather than
    /// `id`. By default, started and then sent the message.
    func startSession(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool,
                      firstMessage: String) async throws -> SessionInfo
    /// Whether the server keeps its sessions' titles, archive and ending
    /// itself. One that does not has them kept on this device, by record
    /// (renaming, archiving and removing work the same to the user).
    var managesSessions: Bool { get }

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
    /// The server's connection codes, as the server itself shows them: the
    /// one its QR code carries, and one leading with each kind of path, so
    /// a device that has the server can hand it on to another.
    func connectionCodes() async throws -> ConnectionCodes

    // MARK: The relay (RelayCourier)

    /// Whether the server takes part in the relay: its agents message
    /// sessions on the other servers this device is connected to, the
    /// messages carried by this device.
    var relays: Bool { get }
    /// Tells the server what this device is connected to: the messages
    /// its agents wrote for sessions on those servers come back, for this
    /// device to carry.
    func relay(_ report: DirectoryReport) async throws -> [RelayMessage]
    /// A message carried here from another server: what became of it.
    /// The same message carried again is answered the same, not taken
    /// twice.
    func deliver(_ message: RelayMessage) async throws -> RelayReceipt
    /// What became of a message from this server, where it went.
    func confirm(_ receipt: RelayReceipt) async throws

    // MARK: Moving a session to another server (SessionMigration)

    /// Whether sessions move to and from this server.
    var migrates: Bool { get }
    /// A session offered for moving elsewhere: its conversation's files and
    /// its projects.
    func migrationOffer(for session: String) async throws -> MigrationOffer
    /// Up to `length` bytes of one of an offer's files from `offset`,
    /// base64, and where the next piece starts.
    func migrationRead(_ offer: String, file: String, offset: Int, length: Int) async throws -> (data: String, next: Int)
    /// A project of an offer's, packed for copying.
    func migrationPack(_ offer: String, project: String) async throws -> MigrationFile
    /// What this server will do with a session offered by another.
    func migrationPlan(for offer: MigrationOffer) async throws -> MigrationPlan
    /// A piece of a file carried here for a move, at `offset`.
    func migrationWrite(_ plan: String, file: String, offset: Int, data: String) async throws
    /// Clones a project the plan said to clone.
    func migrationClone(_ plan: String, step: MigrationStep) async throws
    /// Unpacks a project carried here where its step says.
    func migrationUnpack(_ plan: String, file: String, step: MigrationStep) async throws
    /// Ends a move here, making the chosen steps' folders, the session run
    /// in `cwd` (the plan's when nil): the new session's id, and the
    /// server's sessions.
    func migrationFinish(_ plan: String, steps: [MigrationStep], cwd: String?) async throws -> (session: String, sessions: [SessionInfo])

    // MARK: Identity and SSH

    /// What the server said of itself at the last sign-in: its id and
    /// its own addresses. Nil before a sign-in, and for a server that
    /// says nothing of the kind.
    var identity: ServerIdentity? { get }
    /// Puts this device's SSH public key among the server's user's
    /// authorized keys, so this device comes in over SSH from now on.
    func authorizeSSHKey(_ line: String) async throws
}

public extension AgentServer {
    var racesPaths: Bool { false }
    func authenticate(_ record: AgentServerRecord, byFirstOf paths: [String], headStarts: [Int32],
                      timeouts: [Int32]) async throws -> (name: String?, path: String) {
        var record = record
        record.address = paths.first ?? record.address
        return (try await authenticate(record), record.address)
    }
    var starting: SessionStarting { .inFolders }

    func startSessionInContainer(id: String, agent: AgentKind, title: String, skipPermissions: Bool, repository: String?) async throws -> [SessionInfo] {
        throw AgentServerError.message("This server runs no agents in containers.")
    }
    func startChoices() async throws -> [StartChoice] { [] }
    func startSession(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool,
                      firstMessage: String) async throws -> SessionInfo {
        let started = try await startSession(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skipPermissions, resume: nil)
        let sent = try await sendMessage(id, text: firstMessage, images: [])
        return (sent + started).first { $0.id == id }
            ?? SessionInfo(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skipPermissions, created: 0)
    }
    var managesSessions: Bool { true }
    func account(of agent: AgentKind) async throws -> AgentAccount? { nil }
    func verifyChannel() async -> Bool { true }
    func registerPush(token: String, platform: String, environment: String, topic: String) async throws -> Bool { false }
    func connectionCodes() async throws -> ConnectionCodes { throw AgentServerError.unsupported }
    var relays: Bool { false }
    func relay(_ report: DirectoryReport) async throws -> [RelayMessage] { throw AgentServerError.unsupported }
    func deliver(_ message: RelayMessage) async throws -> RelayReceipt { throw AgentServerError.unsupported }
    func confirm(_ receipt: RelayReceipt) async throws { throw AgentServerError.unsupported }
    var migrates: Bool { false }
    func migrationOffer(for session: String) async throws -> MigrationOffer { throw AgentServerError.unsupported }
    func migrationRead(_ offer: String, file: String, offset: Int, length: Int) async throws -> (data: String, next: Int) {
        throw AgentServerError.unsupported
    }
    func migrationPack(_ offer: String, project: String) async throws -> MigrationFile { throw AgentServerError.unsupported }
    func migrationPlan(for offer: MigrationOffer) async throws -> MigrationPlan { throw AgentServerError.unsupported }
    func migrationWrite(_ plan: String, file: String, offset: Int, data: String) async throws { throw AgentServerError.unsupported }
    func migrationClone(_ plan: String, step: MigrationStep) async throws { throw AgentServerError.unsupported }
    func migrationUnpack(_ plan: String, file: String, step: MigrationStep) async throws { throw AgentServerError.unsupported }
    func migrationFinish(_ plan: String, steps: [MigrationStep], cwd: String?) async throws -> (session: String, sessions: [SessionInfo]) {
        throw AgentServerError.unsupported
    }
    var identity: ServerIdentity? { nil }
    func authorizeSSHKey(_ line: String) async throws { throw AgentServerError.unsupported }
}
