import ClaudeTranscript
import MessageCache
import Foundation
import VisorProtocol

/// What the menu bar app keeps of a session on disk — every session, live
/// or archived, so a relaunch of the app loses nothing: each comes back
/// idle and resumes its agent's own session on the next message.
struct StoredSession: Codable {
    var info: SessionInfo
    var entries: [TranscriptEntry]
    var resumeID: String?
    /// The transcript's shape; older files (nil) grouped a turn's tool calls
    /// after its text and are rebuilt from the agent's own store on load.
    var shape: Int?
    /// The session was mid-turn when the app went away.
    var interrupted: Bool?
    /// The agent's pid at the time of writing, so a later launch can find
    /// one of ours that outlived us.
    var agentPID: Int32?
    /// The prompts the chat had shown, by the agent's own uuids: how a
    /// later reading of the session file tells a fork from progress.
    var shownPrompts: [String]?
    /// A notice the user has not yet acknowledged.
    var notice: String?
    /// The files beside each queued message (`info.queued`).
    var queuedImages: [[String]]?
    /// The agent's running total as it last reported it.
    var reportedUsage: SessionUsage?
    /// The agent's host, when the agent was left running under one for the
    /// next launch to pick up.
    var host: StoredHost?
    /// Where the conversation stood in the agent's file (SessionRecord).
    var head: String?
    var leaf: String?
    var otherBranch: String?
    var branchKept: Bool?
    /// A fork or branch not yet copied by its agent.
    var fork: PendingFork?
    /// The subagents seen running, and those the person closed.
    var watchedSubagents: [String]?
    var closedSubagents: [String]?
    /// The MCP servers it switched from their default (on or off).
    var mcpSwitched: [String: Bool]?
    static let currentShape = 2

    init(info: SessionInfo, entries: [TranscriptEntry], resumeID: String?, shape: Int?,
         interrupted: Bool? = nil, agentPID: Int32? = nil, shownPrompts: [String]? = nil, notice: String? = nil,
         queuedImages: [[String]]? = nil, reportedUsage: SessionUsage? = nil, host: StoredHost? = nil,
         head: String? = nil, leaf: String? = nil, otherBranch: String? = nil, branchKept: Bool? = nil,
         fork: PendingFork? = nil, watchedSubagents: [String]? = nil, closedSubagents: [String]? = nil, mcpSwitched: [String: Bool]? = nil) {
        self.info = info
        self.entries = entries
        self.resumeID = resumeID
        self.shape = shape
        self.interrupted = interrupted
        self.agentPID = agentPID
        self.shownPrompts = shownPrompts
        self.notice = notice
        self.queuedImages = queuedImages
        self.reportedUsage = reportedUsage
        self.host = host
        self.head = head
        self.leaf = leaf
        self.otherBranch = otherBranch
        self.branchKept = branchKept
        self.fork = fork
        self.watchedSubagents = watchedSubagents
        self.closedSubagents = closedSubagents
        self.mcpSwitched = mcpSwitched
    }

    /// Every field but the session itself is optional, so a file written
    /// by a build with fewer of them still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = try c.decode(SessionInfo.self, forKey: .info)
        entries = try c.decodeIfPresent([TranscriptEntry].self, forKey: .entries) ?? []
        resumeID = try c.decodeIfPresent(String.self, forKey: .resumeID)
        shape = try c.decodeIfPresent(Int.self, forKey: .shape)
        interrupted = try c.decodeIfPresent(Bool.self, forKey: .interrupted)
        agentPID = try c.decodeIfPresent(Int32.self, forKey: .agentPID)
        shownPrompts = try c.decodeIfPresent([String].self, forKey: .shownPrompts)
        notice = try c.decodeIfPresent(String.self, forKey: .notice)
        queuedImages = try c.decodeIfPresent([[String]].self, forKey: .queuedImages)
        reportedUsage = try c.decodeIfPresent(SessionUsage.self, forKey: .reportedUsage)
        host = try c.decodeIfPresent(StoredHost.self, forKey: .host)
        head = try c.decodeIfPresent(String.self, forKey: .head)
        leaf = try c.decodeIfPresent(String.self, forKey: .leaf)
        otherBranch = try c.decodeIfPresent(String.self, forKey: .otherBranch)
        branchKept = try c.decodeIfPresent(Bool.self, forKey: .branchKept)
        fork = try c.decodeIfPresent(PendingFork.self, forKey: .fork)
        watchedSubagents = try c.decodeIfPresent([String].self, forKey: .watchedSubagents)
        closedSubagents = try c.decodeIfPresent([String].self, forKey: .closedSubagents)
        mcpSwitched = try c.decodeIfPresent([String: Bool].self, forKey: .mcpSwitched)
    }
}
