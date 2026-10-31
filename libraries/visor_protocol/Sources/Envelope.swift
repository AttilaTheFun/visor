// The wire protocol: JSON envelopes over a WebSocket, one per text frame.
// A client logs in with the host's password, then starts, drives and
// watches agent sessions — Claude Code or Codex processes the menu bar app
// spawns on the host. The server normalises each agent's own JSON stream
// into transcript entries, deltas and activity lines, so a client renders
// one shape for every agent (AgentUI's TranscriptMessage).

#if canImport(Foundation)
import Foundation
#endif

/// Every message, both directions, is one envelope; `type` says which
/// fields are set. Client → server: login, start, send, stop, subscribe,
/// permissions, settings, approve, archive, unarchive, end. Agent side
/// (the permission MCP shim, with the app's token): approval_request;
/// the app answers approval_result. Server → client: welcome, error, sessions, transcript, delta,
/// entry, activity, busy, failure.
public struct Envelope: Codable, Sendable {
    public var type: String
    // login: the password, or a token from `hello`
    public var password: String?
    // welcome / hello
    public var host: String?
    /// hello: the network user the host belongs to (whose devices get in
    /// without a password).
    public var login: String?
    // error / failure
    public var message: String?
    // start: the client's id for the new session
    public var id: String?
    public var agent: AgentKind?
    public var cwd: String?
    /// The session's name; empty means the directory's name.
    public var title: String?
    /// start / permissions: run the agent without permission prompts (auto)
    /// or with the agent's own guarded mode (manual).
    public var skipPermissions: Bool?
    // send / stop / subscribe / end / transcript / delta / entry / activity / busy / failure
    public var session: String?
    public var text: String?
    // sessions / welcome
    public var sessions: [SessionInfo]?
    // welcome: each provider's models
    public var catalogs: [AgentCatalog]?
    /// account: how `agent` is paid for and how near its limits it is,
    /// changed since its catalog was sent.
    public var account: AgentAccount?
    /// start (in a container), contain: what the container is given.
    public var containerSize: ContainerSize?
    // settings: the session's model and effort (nil keeps the current one)
    public var model: String?
    public var effort: String?
    // transcript
    public var entries: [TranscriptEntry]?
    public var streaming: String?
    public var activity: String?
    public var busy: Bool?
    public var error: String?
    // entry
    public var entry: TranscriptEntry?
    // approval (server → client): the request; approve (client → server): id + allow (in `busy`)
    public var approval: ApprovalRequest?
    public var allow: Bool?
    // approval_request (agent shim → server): token + id + text (tool) + prompt (summary)
    public var token: String?
    public var prompt: String?
    // start: the agent's own session to pick up (a resume)
    public var resume: String?
    // folders (a path and its subfolders) / resumable (an agent's sessions)
    public var path: String?
    /// send: pictures the message comes with, as paths on the computer.
    /// They are shown in the transcript and named to the agent.
    public var images: [String]?
    /// folders: whether `path` is still a folder on the computer. A project
    /// whose folder was renamed or moved out from under us answers false.
    public var exists: Bool?
    /// What an agent asks of the other sessions (`agent`): "sessions",
    /// "send", "read" or "status".
    public var mode: String?
    /// Which client is speaking, given at login; for an agent's ask, the
    /// session asking.
    public var client: String?
    /// Something the user is told about the session and acknowledges —
    /// that it was forked elsewhere and the chat now follows the newer
    /// branch. On a transcript until acknowledged, and pushed as it happens.
    public var notice: String?
    /// Bytes, base64: a piece of a file a migration carries.
    public var data: String?
    /// How many of a session's latest rows an agent's read asks for.
    public var rows: Int?
    /// Earlier rows: the id the asked-for rows come before, and whether a
    /// transcript goes back further than what was sent.
    public var before: String?
    public var more: Bool?
    /// The transcript's revision: counts up with every change to its
    /// rows. A client syncing over HTTP asks for the rows past the
    /// revision it has; the answer waits until there is one.
    public var revision: Int?
    /// The transcript's generation: a different one means the client's
    /// revision can no longer be caught up by a delta (the server started
    /// again, or let go of what it removed), and the answer is the rows as
    /// a whole.
    public var generation: Int?
    /// In a delta, for each row of `entries`, the row it follows ("" for
    /// the first): new rows go there, and rows that moved move there.
    public var after: [String]?
    /// In a delta, the rows removed since the revision asked about.
    public var removed: [String]?
    /// The rows are the whole, not a delta: the client replaces what it
    /// holds (its cache too) and draws the thread again.
    public var reset: Bool?
    /// In a delta, more changed rows follow these: the client takes these,
    /// and asks again for the rows changed since the same revision after
    /// the last of them (`?after=<id>`). A client far behind catches up a
    /// page at a time, in order.
    public var later: Bool?
    /// In a whole answer, the row its first row follows on the computer
    /// ("" when it is the thread's first; nil when not known): a client
    /// that keeps that row keeps the rows before it too.
    public var follows: String?
    /// `fork`: the session a fork or branch is made from, how, and the
    /// message of its conversation a branch goes on from (nil: its end).
    public var parent: String?
    public var origin: SessionOrigin?
    public var at: String?
    /// `fork` with the `subagent` origin: the parent's subagent whose
    /// conversation the session goes on with.
    public var subagent: String?
    /// In a session's state, a sign-in waiting for its code (`/login`):
    /// the page to sign in at. What the user sends next goes to it.
    public var signIn: String?
    /// approval_request (agent shim → server): what the agent asks the
    /// user (AskUserQuestion), as it gave it.
    public var questions: [AgentQuestion]?
    /// approve (client → server) and approval_result (server → shim): the
    /// user's answers to those questions, by question; several answers to
    /// one joined with ", ".
    public var answers: [String: String]?
    /// The turn's status lines so far — tool calls, subagents, shells,
    /// thinking — as the computer keeps them.
    public var status: [StatusItem]?
    /// What is streaming, or streamed and not yet on the record, one
    /// assistant message each, in an ephemeral snapshot.
    public var streams: [StreamChunk]?
    public var folders: [String]?
    public var resumable: [ResumableSession]?
    /// The slash commands a session's agent takes (`commands`).
    public var commands: [SlashCommand]?
    /// `hello`: the server's own addresses, as clients read them.
    public var addresses: [String]?
    /// An agent's request about a session on another server: that server,
    /// by its id or its name ("" or nil: this one).
    public var server: String?
    /// A relayed message's id: what an agent asks after (`message_status`).
    public var messageID: String?
    /// `POST /api/relay`: the client's report of the servers and sessions
    /// it is connected to.
    public var report: DirectoryReport?
    /// Relayed messages: in the answer to `POST /api/relay`, those waiting
    /// for a server the client reported; in `POST /api/relay/deliver`, the
    /// one being delivered.
    public var relayed: [RelayMessage]?
    /// `POST /api/relay/deliver`'s answer and `POST /api/relay/receipt`'s
    /// body: what became of a relayed message.
    public var receipt: RelayReceipt?
    /// `GET /api/codes`: the server's connection codes.
    public var codes: ConnectionCodes?
    /// `hello`: the server stands alone — reached only at the address a
    /// client added it at (a front of its own: an authenticating proxy),
    /// its own addresses not shared, and kept out of the relay.
    public var standalone: Bool?
    /// `hello`: false when the server asks clients not to keep its
    /// sessions' messages on their disk — each holds only the pages it
    /// shows, in memory, and asks again for those it let go of. Absent:
    /// they may.
    public var keepMessages: Bool?
    /// `start`: the session's agent runs in a container on the server's
    /// computer rather than on the computer itself, its folder mounted
    /// there. `contain`: the session moves into its container (true) or out
    /// of it (false). `hello` and `sessions`: the server can run one.
    public var container: Bool?
    /// A device's push token, hex (`push`), with its kind ("ios", "macos")
    /// and service ("sandbox", "production").
    public var deviceToken: String?
    public var platform: String?
    public var pushEnvironment: String?
    /// The app a push token is for: its bundle id.
    public var pushTopic: String?
    /// Moving a session to another server (VisorServer+Migration.swift):
    /// the move it is part of (an offer's token where the session was, a
    /// plan's id where it goes), what the session's server offers, what
    /// the other will do, the steps chosen or the one taken, the file read
    /// or written, and where in it (`data` holds the bytes, base64).
    /// `hello`: the server's version and build, as installed and running
    /// ("0.31 (8)").
    public var version: String?
    public var migration: String?
    public var offer: MigrationOffer?
    public var plan: MigrationPlan?
    public var steps: [MigrationStep]?
    public var file: MigrationFile?
    public var offset: Int?

    public init(type: String) { self.type = type }

    public static let defaultPort: UInt16 = 7433
}

extension Envelope {
    /// Everything about a session that is not the record, in one piece,
    /// sent when a client subscribes so nothing ephemeral is missed:
    /// the streams, the status lines, the activity, busy, the approval
    /// waiting, the queue, the notice.
    public static func ephemeral(session: String, streams: [StreamChunk], status: [StatusItem], activity: String?, busy: Bool,
                                 approval: ApprovalRequest?, queued: [String], notice: String?, signIn: String? = nil) -> Envelope {
        var e = Envelope(type: "ephemeral"); e.session = session; e.streams = streams; e.status = status
        e.activity = activity; e.busy = busy; e.approval = approval; e.notice = notice; e.signIn = signIn
        if !queued.isEmpty { e.folders = queued }
        return e
    }
    /// The turn's status lines changed.
    public static func status(session: String, items: [StatusItem]) -> Envelope {
        var e = Envelope(type: "status"); e.session = session; e.status = items; return e
    }
    public static func login(password: String, token: String? = nil, client: String) -> Envelope {
        var e = Envelope(type: "login"); e.password = password; e.token = token; e.client = client; return e
    }
    /// The host's answer to a client it recognises: its name, whose it
    /// is, and a token for the socket's login.
    public static func hello(host: String, login: String, token: String) -> Envelope {
        var e = Envelope(type: "hello"); e.host = host; e.login = login; e.token = token; return e
    }
    public static func start(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool,
                             resume: String? = nil) -> Envelope {
        var e = Envelope(type: "start"); e.id = id; e.agent = agent; e.cwd = cwd; e.title = title; e.skipPermissions = skipPermissions
        e.resume = resume; return e
    }
    /// A session whose agent runs in a container on the server's computer,
    /// working in `cwd` there (mounted in the container at the same path).
    public static func startInContainer(id: String, agent: AgentKind, cwd: String, title: String, skipPermissions: Bool,
                                        size: ContainerSize? = nil) -> Envelope {
        var e = start(id: id, agent: agent, cwd: cwd, title: title, skipPermissions: skipPermissions)
        e.container = true
        e.containerSize = size
        return e
    }
    /// A fork or a branch of `parent`, a session on the same server: the
    /// same folder, computer or container, agent, model and permissions,
    /// and its conversation so far (up to `at`, a message's id, for a
    /// branch). `text`, when given, is said to it first (a fork's prompt).
    /// With the `subagent` origin, its conversation is that of `subagent`,
    /// one of the parent's that has finished.
    public static func fork(id: String, parent: String, origin: SessionOrigin, at: String? = nil, text: String? = nil,
                            title: String = "", subagent: String? = nil) -> Envelope {
        var e = Envelope(type: "fork"); e.id = id; e.parent = parent; e.origin = origin; e.at = at; e.text = text
        e.title = title; e.subagent = subagent; return e
    }
    /// A side question about `session`'s conversation (`/btw`), by the
    /// client's id for it: answered on the session's `side`, not added to
    /// its conversation.
    public static func side(session: String, id: String, question: String) -> Envelope {
        var e = Envelope(type: "side"); e.session = session; e.id = id; e.text = question; return e
    }
    /// The person is done with `session`'s side questions: they go.
    public static func endSide(session: String) -> Envelope {
        var e = Envelope(type: "endSide"); e.session = session; return e
    }
    /// The person's words to one of `session`'s subagents (`id`): handed
    /// to the session's agent to pass on, while the subagent runs.
    public static func toSubagent(session: String, id: String, text: String) -> Envelope {
        var e = Envelope(type: "toSubagent"); e.session = session; e.id = id; e.text = text; return e
    }
    /// One of the MCP servers this computer passes on to its agents
    /// switched on or off for `session` (by the endpoint's name, `allow`
    /// on), taking effect at its agent's next look at its tools.
    public static func mcp(session: String, endpoint: String, on: Bool) -> Envelope {
        var e = Envelope(type: "mcp"); e.session = session; e.id = endpoint; e.allow = on; return e
    }
    /// The person closes one of `session`'s subagents: its row and capsule go.
    public static func closeSubagent(session: String, id: String) -> Envelope {
        var e = Envelope(type: "closeSubagent"); e.session = session; e.id = id; return e
    }
    /// Moves a session's agent into a container on its computer (`true`) or
    /// out of it onto the computer itself (`false`): the same folder and
    /// conversation, its agent started again on the other side.
    /// With a size, into a container given that much.
    public static func contain(session: String, _ container: Bool, size: ContainerSize? = nil) -> Envelope {
        var e = Envelope(type: "contain"); e.session = session; e.container = container; e.containerSize = size; return e
    }
    public static func send(session: String, text: String, images: [String] = []) -> Envelope {
        var e = Envelope(type: "send"); e.session = session; e.text = text
        if !images.isEmpty { e.images = images }
        return e
    }
    /// The user has read the session's notice.
    public static func acknowledge(session: String) -> Envelope {
        var e = Envelope(type: "acknowledge"); e.session = session; return e
    }
    /// Asks for the rows before `before` of a thread served from its end.
    public static func earlier(session: String, before: String) -> Envelope {
        var e = Envelope(type: "earlier"); e.session = session; e.before = before; return e
    }
    public static func stop(session: String) -> Envelope {
        var e = Envelope(type: "stop"); e.session = session; return e
    }
    public static func subscribe(session: String) -> Envelope {
        var e = Envelope(type: "subscribe"); e.session = session; return e
    }
    /// Stops following a session the client has left: its state and
    /// streamed words are sent no more (a server before 0.33 says it does
    /// not know the message, which the client lets pass).
    /// The code a sign-in page showed, for the session's sign-in.
    public static func signIn(session: String, code: String) -> Envelope {
        var e = Envelope(type: "signIn"); e.session = session; e.text = code; return e
    }
    public static func unsubscribe(session: String) -> Envelope {
        var e = Envelope(type: "unsubscribe"); e.session = session; return e
    }
    public static func permissions(session: String, skipPermissions: Bool) -> Envelope {
        var e = Envelope(type: "permissions"); e.session = session; e.skipPermissions = skipPermissions; return e
    }
    public static func settings(session: String, model: String?, effort: String?) -> Envelope {
        var e = Envelope(type: "settings"); e.session = session; e.model = model; e.effort = effort; return e
    }
    public static func approve(session: String, id: String, allow: Bool, answers: [String: String]? = nil) -> Envelope {
        var e = Envelope(type: "approve"); e.session = session; e.id = id; e.allow = allow; e.answers = answers; return e
    }
    public static func approval(session: String, _ request: ApprovalRequest?) -> Envelope {
        var e = Envelope(type: "approval"); e.session = session; e.approval = request; return e
    }
    public static func rename(session: String, title: String) -> Envelope {
        var e = Envelope(type: "rename"); e.session = session; e.title = title; return e
    }
    public static func archive(session: String) -> Envelope {
        var e = Envelope(type: "archive"); e.session = session; return e
    }
    public static func unarchive(session: String) -> Envelope {
        var e = Envelope(type: "unarchive"); e.session = session; return e
    }
    public static func end(session: String) -> Envelope {
        var e = Envelope(type: "end"); e.session = session; return e
    }

    public static func welcome(host: String, sessions: [SessionInfo], catalogs: [AgentCatalog]) -> Envelope {
        var e = Envelope(type: "welcome"); e.host = host; e.sessions = sessions; e.catalogs = catalogs; return e
    }
    /// The agents on offer changed (a key was entered on the server).
    public static func catalogs(_ catalogs: [AgentCatalog]) -> Envelope {
        var e = Envelope(type: "catalogs"); e.catalogs = catalogs; return e
    }
    /// An agent's account changed: its plan, or how near its limits it is.
    public static func account(_ account: AgentAccount, of agent: AgentKind) -> Envelope {
        var e = Envelope(type: "account"); e.agent = agent; e.account = account; return e
    }
    /// The client's heartbeat over the live channel, and the server's
    /// answer to it: a channel that goes unanswered is taken as dropped.
    public static func ping() -> Envelope { Envelope(type: "ping") }
    public static func pong() -> Envelope { Envelope(type: "pong") }
    public static func error(_ message: String) -> Envelope {
        var e = Envelope(type: "error"); e.message = message; return e
    }
    public static func sessions(_ sessions: [SessionInfo]) -> Envelope {
        var e = Envelope(type: "sessions"); e.sessions = sessions; return e
    }
    public static func transcript(session: String, entries: [TranscriptEntry], streaming: String, activity: String?, busy: Bool, error: String?) -> Envelope {
        var e = Envelope(type: "transcript"); e.session = session; e.entries = entries; e.streaming = streaming; e.activity = activity; e.busy = busy; e.error = error; return e
    }
    /// Words streamed for one assistant message, named by the message's
    /// own id, so a client keeps each message as its own row — and keeps
    /// it, complete, until the transcript carries a row with that id.
    public static func delta(session: String, message id: String, text: String) -> Envelope {
        var e = Envelope(type: "delta"); e.session = session; e.id = id; e.text = text; return e
    }
    /// A new entry, or a replacement for the entry with the same id.
    public static func entry(session: String, _ entry: TranscriptEntry) -> Envelope {
        var e = Envelope(type: "entry"); e.session = session; e.entry = entry; return e
    }
    public static func activity(session: String, _ activity: String?) -> Envelope {
        var e = Envelope(type: "activity"); e.session = session; e.activity = activity; return e
    }
    public static func busy(session: String, _ busy: Bool) -> Envelope {
        var e = Envelope(type: "busy"); e.session = session; e.busy = busy; return e
    }
    public static func failure(session: String, _ message: String) -> Envelope {
        var e = Envelope(type: "failure"); e.session = session; e.message = message; return e
    }
}
