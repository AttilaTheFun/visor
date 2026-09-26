// The wire protocol: JSON envelopes over a WebSocket, one per text frame.
// A client logs in with the host's password, then starts, drives and
// watches agent sessions — Claude Code or Codex processes the menu bar app
// spawns on the host. The server normalises each agent's own JSON stream
// into transcript entries, deltas and activity lines, so a client renders
// one shape for every agent (AgentUI's TranscriptMessage).

#if canImport(Foundation)
import Foundation
#endif

/// One thing a turn is doing or has done, as streamed — the model
/// thinking, a shell running, a monitor watching, a subagent working, a
/// tool called, the task list as it stands. Ephemeral: never the record.
public struct StatusItem: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case thinking, shell, monitor, subagent, tool, tasks }
    public var id: String
    public var kind: Kind
    public var label: String
    public var running: Bool
    /// For `.tasks`: the list as last written.
    public var tasks: [TaskItem]
    public init(id: String, kind: Kind, label: String, running: Bool, tasks: [TaskItem] = []) {
        self.id = id; self.kind = kind; self.label = label; self.running = running; self.tasks = tasks
    }
}

public struct TaskItem: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pending, active, done }
    public var title: String
    public var state: State
    public init(title: String, state: State) { self.title = title; self.state = state }
}

/// Which command-line agent a session runs.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case openrouter

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .openrouter: "OpenRouter"
        }
    }

    /// A kind as named on the wire or in a store. A name no longer
    /// offered ("ori", a Claude-protocol harness that OpenRouter replaced)
    /// reads as Claude, so what was kept under it still opens.
    public init?(wire: String) {
        if wire == "ori" { self = .claude } else { self.init(rawValue: wire) }
    }

    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        self = AgentKind(wire: name) ?? .claude
    }

    /// The command-line tool.
    public var tool: String { rawValue }
}

/// A session in an agent's own store on the host, resumable here.
public struct ResumableSession: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var agent: AgentKind
    public var cwd: String
    /// The first prompt, shortened.
    public var title: String
    /// Seconds since 1970 (the file's last change).
    public var timestamp: Double

    public init(id: String, agent: AgentKind, cwd: String, title: String, timestamp: Double) {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.title = title
        self.timestamp = timestamp
    }
}

/// One of a provider's models, as the host lists them (Codex: from its
/// models cache; Claude: the CLI's aliases).
public struct AgentModel: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    /// The effort levels this model takes, in order.
    public var efforts: [String]
    public var defaultEffort: String?
    /// Who makes it ("OpenAI"), for a list grouped by maker.
    public var group: String?
    /// In the short list a picker opens on; false for the long tail,
    /// shown only under All Models.
    public var listed: Bool

    public init(id: String, title: String, subtitle: String? = nil, efforts: [String], defaultEffort: String? = nil,
                group: String? = nil, listed: Bool = true) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.group = group
        self.listed = listed
    }
}

/// A provider's models and its default, sent with `welcome`.
public struct AgentCatalog: Codable, Hashable, Sendable {
    public var agent: AgentKind
    public var models: [AgentModel]
    public var defaultModel: String?
    /// The tool is installed on the host.
    public var available: Bool

    public init(agent: AgentKind, models: [AgentModel], defaultModel: String? = nil, available: Bool = true) {
        self.agent = agent
        self.models = models
        self.defaultModel = defaultModel
        self.available = available
    }

    /// The model a session runs: its own, else the provider's default.
    public func model(matching id: String?) -> AgentModel? {
        let wanted = id ?? defaultModel
        if let wanted, let exact = models.first(where: { $0.id == wanted }) { return exact }
        // Claude reports the full name ("claude-fable-5-1") for an alias ("fable").
        if let wanted, let byPrefix = models.first(where: { wanted.contains($0.id) }) { return byPrefix }
        // And its list names some by alias with a context mark ("opus[1m]",
        // "claude-fable-5-1[1m]"), which a reported or older name reaches
        // without the mark. Not for provider/model ids, where a name inside
        // another is a different model.
        if let wanted, !wanted.contains("/") {
            func bare(_ id: String) -> String { id.split(separator: "[").first.map(String.init) ?? id }
            let plain = bare(wanted)
            if let loose = models.first(where: { plain.contains(bare($0.id)) || bare($0.id).contains(plain) }) { return loose }
        }
        return nil
    }

    /// A model id as a name: the catalog's title, or the id tidied up
    /// ("claude-haiku-4-5-20251001" → "Haiku 4.5").
    public func title(for id: String?) -> String? {
        if let model = model(matching: id) { return model.title }
        guard let id else { return nil }
        return AgentCatalog.prettyModelName(id)
    }

    public static func prettyModelName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        var name: [String] = []
        var version: [String] = []
        for part in parts {
            if part == "claude" || part == "gpt" { continue }
            if part.allSatisfy(\.isNumber) {
                if part.count <= 2 { version.append(part) }
            } else {
                name.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        let head = name.joined(separator: " ")
        return version.isEmpty ? head : head + " " + version.joined(separator: ".")
    }

    public static func effortTitle(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra high"
        case "ultra": "Ultra"
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}

/// A tool call waiting for the user's Allow or Deny (manual mode).
public struct ApprovalRequest: Codable, Hashable, Sendable {
    public var id: String
    /// The tool ("Bash", "Edit"…).
    public var tool: String
    /// One line of what it wants to do.
    public var summary: String

    public init(id: String, tool: String, summary: String) {
        self.id = id
        self.tool = tool
        self.summary = summary
    }
}

/// One session, as the sidebar lists it.
/// Which process holds a session, and — when it is the agent's own
/// terminal — whose window it is drawn for. A terminal interface is
/// rendered on the computer at one fixed size, so it belongs to exactly
/// one client: the mode carries that client and its window, and there is
/// no way to be in the terminal without them.
public enum SessionMode: Hashable, Sendable {
    /// The headless process, drawn by each client for its own screen.
    case chat
    /// The agent's own interface on a terminal of `cols` × `rows`,
    /// drawn for the client that took control.
    case tui(controller: String, cols: Int, rows: Int)

    public var isTUI: Bool { if case .tui = self { true } else { false } }

    /// The client the terminal is drawn for, if any.
    public var controller: String? {
        if case .tui(let controller, _, _) = self { controller } else { nil }
    }

    public var terminalSize: (cols: Int, rows: Int)? {
        if case .tui(_, let cols, let rows) = self { (cols, rows) } else { nil }
    }

    /// Whether this client is the one the terminal is drawn for.
    public func controlled(by client: String?) -> Bool {
        guard let controller, let client, !client.isEmpty else { return false }
        return controller == client
    }
}

extension SessionMode: Codable {
    private enum CodingKeys: String, CodingKey { case kind, controller, cols, rows }

    public init(from decoder: Decoder) throws {
        // Older stores wrote a bare string. A terminal needs a client and
        // a window, and neither survives a restart, so it comes back chat.
        if let single = try? decoder.singleValueContainer(), let _ = try? single.decode(String.self) {
            self = .chat
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decodeIfPresent(String.self, forKey: .kind) == "tui",
              let controller = try c.decodeIfPresent(String.self, forKey: .controller),
              let cols = try c.decodeIfPresent(Int.self, forKey: .cols),
              let rows = try c.decodeIfPresent(Int.self, forKey: .rows)
        else {
            self = .chat
            return
        }
        self = .tui(controller: controller, cols: cols, rows: rows)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .chat:
            try c.encode("chat", forKey: .kind)
        case .tui(let controller, let cols, let rows):
            try c.encode("tui", forKey: .kind)
            try c.encode(controller, forKey: .controller)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
        }
    }
}

public struct SessionInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var agent: AgentKind
    /// The working directory the agent runs in.
    public var cwd: String
    /// The session's name: the client's, or the directory's name.
    public var title: String
    /// The agent is working on a turn.
    public var busy: Bool
    /// The agent is blocked on a permission the user has to grant.
    public var pendingApproval: ApprovalRequest?
    /// The process is gone (stopped by the user or exited); the transcript remains.
    public var ended: Bool
    /// Auto: the agent runs without permission prompts. Manual: Claude's
    /// acceptEdits / Codex's workspace-write sandbox. Switchable mid-session.
    public var skipPermissions: Bool
    /// Put away: the process was exited gracefully; the transcript and the
    /// agent's own session id are kept, so it resumes with the same
    /// parameters on unarchive (or on the next message).
    public var archived: Bool
    /// How to resume the agent's own session in a terminal, once known
    /// ("cd … && claude --resume <id>").
    public var resumeCommand: String?
    /// The model the user chose (nil: the provider's default). This alone
    /// drives what the agent is launched with, and only the user changes
    /// it — a turn that fell back to another model never overwrites it.
    public var model: String?
    /// The model a turn actually ran on, as the agent reported it: for
    /// display, so a fallback is visible; never for launching.
    public var reportedModel: String?
    /// The effort level (nil: the model's default).
    public var effort: String?
    /// Tokens the agent's last request carried (its context), and the
    /// model's window. Both nil until a turn reports them.
    public var contextUsed: Int?
    public var contextLimit: Int?
    /// What the user has said while the agent was working, in the order it
    /// was said. A turn in flight is not interrupted for it: the queue is
    /// handed over when the agent next falls idle.
    public var queued: [String] = []
    /// Seconds since 1970.
    public var created: Double
    /// Chat unless switched: the terminal holds the session while the
    /// user drives it interactively, the chat process otherwise.
    public var mode: SessionMode = .chat
    /// The start of the latest message, for a list of sessions to show
    /// under each; nil before anything is said.
    public var preview: String?
    /// When the latest message arrived, seconds since 1970; nil before
    /// anything is said (the list falls back to `created`).
    public var updated: Double?

    public init(id: String, agent: AgentKind, cwd: String, title: String, busy: Bool = false, ended: Bool = false,
                skipPermissions: Bool = true, archived: Bool = false, resumeCommand: String? = nil,
                model: String? = nil, effort: String? = nil, created: Double) {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.title = title
        self.busy = busy
        self.pendingApproval = nil
        self.ended = ended
        self.skipPermissions = skipPermissions
        self.archived = archived
        self.resumeCommand = resumeCommand
        self.model = model
        self.effort = effort
        self.created = created
    }

    // Decoded field by field, every one of them optional but `id`. The
    // store on disk was written by an older build, and a synthesised
    // decoder throws on a key that build had never heard of: adding one
    // non-optional property (`queued`) made every stored session
    // unreadable at a stroke, and the file was then written back empty.
    // A missing key is a default from here on.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .claude
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? "~"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        busy = try c.decodeIfPresent(Bool.self, forKey: .busy) ?? false
        pendingApproval = try c.decodeIfPresent(ApprovalRequest.self, forKey: .pendingApproval)
        ended = try c.decodeIfPresent(Bool.self, forKey: .ended) ?? false
        skipPermissions = try c.decodeIfPresent(Bool.self, forKey: .skipPermissions) ?? true
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        resumeCommand = try c.decodeIfPresent(String.self, forKey: .resumeCommand)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        reportedModel = try c.decodeIfPresent(String.self, forKey: .reportedModel)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        contextUsed = try c.decodeIfPresent(Int.self, forKey: .contextUsed)
        contextLimit = try c.decodeIfPresent(Int.self, forKey: .contextLimit)
        queued = try c.decodeIfPresent([String].self, forKey: .queued) ?? []
        created = try c.decodeIfPresent(Double.self, forKey: .created) ?? 0
        mode = try c.decodeIfPresent(SessionMode.self, forKey: .mode) ?? .chat
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        updated = try c.decodeIfPresent(Double.self, forKey: .updated)
    }
}

/// A picture's size in pixels.
public struct ImageSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// One transcript row: what AgentUI's TranscriptMessage carries, on the wire.
public struct TranscriptEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, tool }

    public var id: String
    public var role: Role
    public var text: String
    /// An assistant turn's tool calls, as activity labels ("Bash: ls").
    public var activities: [String]
    /// A tool result's tool name.
    public var toolName: String?
    /// Pictures that came with this row, as paths on the computer: a
    /// screenshot the agent took, an image it was shown. The client asks
    /// the computer for the bytes when it draws them.
    public var images: [String] = []
    /// Each picture's size in pixels, in the order of `images`, so a row
    /// can be laid out at its final size before the bytes arrive — a
    /// transcript that reshapes itself as each picture lands is a
    /// transcript that jumps. Shorter than `images` when a size is not
    /// known (a picture the computer could not read).
    public var imageSizes: [ImageSize] = []

    public init(id: String, role: Role, text: String, activities: [String] = [], toolName: String? = nil,
                images: [String] = [], imageSizes: [ImageSize] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.activities = activities
        self.toolName = toolName
        self.images = images
        self.imageSizes = imageSizes
    }

    /// Tolerant of a file written by a build that knew fewer fields, for
    /// the same reason SessionInfo is.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .assistant
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        activities = try c.decodeIfPresent([String].self, forKey: .activities) ?? []
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
        imageSizes = try c.decodeIfPresent([ImageSize].self, forKey: .imageSizes) ?? []
    }
}

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

    public init(type: String) { self.type = type }

    public static let defaultPort: UInt16 = 7433
}

/// A streamed assistant message in a snapshot: its id and its words so far.
public struct StreamChunk: Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
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
    /// Tells a subscriber something about the session that waits to be read.
    public static func notice(session: String, _ message: String) -> Envelope {
        var e = Envelope(type: "notice"); e.session = session; e.notice = message; return e
    }
    /// The user has read the session's notice.
    public static func acknowledge(session: String) -> Envelope {
        var e = Envelope(type: "acknowledge"); e.session = session; return e
    }
    /// Takes control of a session: the agent's own terminal, drawn for
    /// this client's window.
    public static func assumeControl(session: String, cols: Int, rows: Int) -> Envelope {
        var e = Envelope(type: "mode"); e.session = session; e.mode = "tui"; e.cols = cols; e.rows = rows; return e
    }

    /// Hands the session back to the chat, which every client can draw.
    public static func returnToChat(session: String) -> Envelope {
        var e = Envelope(type: "mode"); e.session = session; e.mode = "chat"; return e
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
