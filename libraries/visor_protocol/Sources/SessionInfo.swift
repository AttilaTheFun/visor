#if canImport(Foundation)
import Foundation
#endif

/// One session, as the sidebar lists it.
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
    /// The goal the agent is working toward (`/goal`), until it is met or
    /// cleared.
    public var goal: String?
    /// A loop the agent set itself (`/loop`): the next time it wakes,
    /// seconds since 1970, or the cron schedule it repeats on.
    public var loopWake: Double?
    public var loopCron: String?

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
        goal = try c.decodeIfPresent(String.self, forKey: .goal)
        loopWake = try c.decodeIfPresent(Double.self, forKey: .loopWake)
        loopCron = try c.decodeIfPresent(String.self, forKey: .loopCron)
    }
}
