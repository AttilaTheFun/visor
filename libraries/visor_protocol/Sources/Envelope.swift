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
    /// A session's mode ("chat" / "tui"), asked for or reported.
    public var mode: String?
    /// Which client a terminal is drawn for.
    public var controller: String?
    /// Which client is speaking, given at login.
    public var client: String?
    /// Something the user is told about the session and acknowledges —
    /// that it was forked elsewhere and the chat now follows the newer
    /// branch. On a transcript until acknowledged, and pushed as it happens.
    public var notice: String?
    /// Terminal bytes, base64: what the PTY produced, or what the user typed.
    public var data: String?
    /// The terminal's size, in cells.
    public var cols: Int?
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
    /// A device's push token, hex (`push`), with its kind ("ios", "macos")
    /// and service ("sandbox", "production").
    public var deviceToken: String?
    public var platform: String?
    public var pushEnvironment: String?
    /// The app a push token is for: its bundle id.
    public var pushTopic: String?

    public init(type: String) { self.type = type }

    public static let defaultPort: UInt16 = 7433
}

extension Envelope {
    /// Everything about a session that is not the record, in one piece,
    /// sent when a client subscribes so nothing ephemeral is missed:
    /// the streams, the status lines, the activity, busy, the approval
    /// waiting, the queue, the notice.
    public static func ephemeral(session: String, streams: [StreamChunk], status: [StatusItem], activity: String?, busy: Bool,
                                 approval: ApprovalRequest?, queued: [String], notice: String?) -> Envelope {
        var e = Envelope(type: "ephemeral"); e.session = session; e.streams = streams; e.status = status
        e.activity = activity; e.busy = busy; e.approval = approval; e.notice = notice
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
    public static func send(session: String, text: String, images: [String] = []) -> Envelope {
        var e = Envelope(type: "send"); e.session = session; e.text = text
        if !images.isEmpty { e.images = images }
        return e
    }
    /// The user has read the session's notice.
    public static func acknowledge(session: String) -> Envelope {
        var e = Envelope(type: "acknowledge"); e.session = session; return e
    }
    /// Takes a terminal session for this client's window: its shell is
    /// drawn at this size, for this client, from now on.
    public static func assumeControl(session: String, cols: Int, rows: Int) -> Envelope {
        var e = Envelope(type: "mode"); e.session = session; e.mode = "tui"; e.cols = cols; e.rows = rows; return e
    }

    /// Bytes typed into the terminal, base64.
    public static func input(session: String, data: String) -> Envelope {
        var e = Envelope(type: "input"); e.session = session; e.data = data; return e
    }
    public static func resize(session: String, cols: Int, rows: Int) -> Envelope {
        var e = Envelope(type: "resize"); e.session = session; e.cols = cols; e.rows = rows; return e
    }
    /// Bytes the terminal produced, base64.
    public static func tty(session: String, data: String) -> Envelope {
        var e = Envelope(type: "tty"); e.session = session; e.data = data; return e
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
    public static func permissions(session: String, skipPermissions: Bool) -> Envelope {
        var e = Envelope(type: "permissions"); e.session = session; e.skipPermissions = skipPermissions; return e
    }
    public static func settings(session: String, model: String?, effort: String?) -> Envelope {
        var e = Envelope(type: "settings"); e.session = session; e.model = model; e.effort = effort; return e
    }
    public static func approve(session: String, id: String, allow: Bool) -> Envelope {
        var e = Envelope(type: "approve"); e.session = session; e.id = id; e.allow = allow; return e
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
