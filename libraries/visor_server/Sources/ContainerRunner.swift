// The container runner's agents (docs/containers.md, "Placing sessions"):
// each agent Visor starts itself in its Sessions container for a session
// placed there, by its id. Nothing claims them: the server makes each one
// (VisorServer+ContainerRunner) with its own token (a JWT for
// `visor.runner-agent` naming the session and the agent, as a runner's
// agent's), and its wrapper dials the driver with it. The driver asks here
// whether a call's token is the agent's, which session it carries on, and
// the conversation it was moved with (DrivenAgentDirectory). An agent let
// go (stopped, restarted, moved back, ended) is told to stop by its
// session's process; if it hasn't ended within `releaseGrace` it's sent
// TERM, then KILL as long again after.

import Foundation

@MainActor
package final class ContainerRunner: DrivenAgentDirectory {
    /// A session placed in the Sessions container: its move's runner
    /// (AgentJobMove.runsOn), and its agents' AGENT_RUNNER (the container's
    /// name).
    package static let runsOn = "visor-sessions"
    /// How soon after its start an agent that ends is taken for one that
    /// didn't get going.
    static let quickEnd: TimeInterval = 60
    /// How many such ends in a row stop its session (it says why) rather
    /// than start it again.
    static let quickEndsAllowed = 3

    /// One agent in the container.
    struct Placed {
        /// The session it carries on.
        let session: String
        /// The conversation its session moved in with, and where that was
        /// here (the driver's Conversation sends it).
        let resume: String
        let cwd: String
        /// When it was started.
        let started: Date
        /// Its process in the container, once started.
        var run: (any ContainerAgentRun)?
        /// Wanted no more: its end starts nothing.
        var released = false
    }

    private(set) var agents: [String: Placed] = [:]
    /// How many times in a row each session's agent ended soon after it
    /// started (quickEnd): reset by one that ran longer.
    var quickEnds: [String: Int] = [:]
    /// The sessions whose agents wait for the container to be given (a
    /// server's start: its engine comes after its sessions are read).
    var waiting: Set<String> = []
    /// The server's tokens.
    let tokens: AgentTokens
    /// Whether a session is live (true), archived (false), or gone (nil).
    var liveSession: (String) -> Bool?
    /// The harness its agents run ("claude"; "echo" for a test without a
    /// model): the driver's, as its jobs have it.
    package var harness = "claude"
    /// How long an agent let go has to end before it's sent TERM (and, as
    /// long again after, KILL).
    package var releaseGrace: Duration = .seconds(10)
    package var now: () -> Date = { Date() }

    init(tokens: AgentTokens, liveSession: @escaping (String) -> Bool?) {
        self.tokens = tokens
        self.liveSession = liveSession
    }

    /// `agent` known as one of `session`'s, before it's started: its
    /// wrapper may dial in as soon as it starts.
    func place(_ agent: String, session: String, resume: String, cwd: String) {
        agents[Self.key(agent)] = Placed(session: session, resume: resume, cwd: cwd, started: now())
    }

    /// `agent`'s process, once started.
    func started(_ agent: String, run: any ContainerAgentRun) {
        agents[Self.key(agent)]?.run = run
    }

    /// `agent` gone (it ended, or didn't start): what was kept of it.
    func ended(_ agent: String) -> Placed? {
        agents.removeValue(forKey: Self.key(agent))
    }

    /// `agent` wanted no more: its end starts nothing, and if it hasn't
    /// ended within `after` (the release grace unless given) it's sent
    /// TERM, then KILL.
    func release(_ agent: String, after: Duration? = nil) {
        let id = Self.key(agent)
        guard agents[id] != nil, agents[id]?.released == false else { return }
        agents[id]?.released = true
        let grace = after ?? releaseGrace
        Task { [weak self] in
            for signal: Int32 in [15, 9] {
                try? await Task.sleep(for: grace)
                guard let run = self?.agents[id]?.run else { return }
                await run.signal(signal)
            }
        }
    }

    /// Every agent of `session` let go (it's moving back, ended or
    /// archived).
    func release(session: String, after: Duration? = nil) {
        waiting.remove(session)
        for (agent, placed) in agents where placed.session == session { release(agent, after: after) }
    }

    /// The agents running now (not let go), by session.
    var runningSessions: Set<String> {
        Set(agents.values.filter { !$0.released }.map(\.session))
    }

    // MARK: - DrivenAgentDirectory

    package func holds(_ agent: String) -> Bool {
        agents[Self.key(agent)] != nil
    }

    package func access(_ agent: String, bearers: [String], withinGrace: Bool, now: Date) -> DrivenAgentAccess {
        let id = Self.key(agent)
        guard let placed = agents[id] else { return .unknown }
        let shown = bearers.filter { !$0.isEmpty }
        guard !shown.isEmpty else { return .refused("The call shows no token (authorization: Bearer <AGENT_TOKEN>).") }
        var why = "That token isn't this agent's."
        var expired = false
        for bearer in shown where JWT.isShaped(bearer) {
            switch tokens.verify(bearer, as: .runnerAgent, agent: id, scope: .job, now: now) {
            case .success(let claims):
                guard claims.sub == placed.session else {
                    why = "That token is another session's."
                    continue
                }
                if liveSession(claims.sub) != true { return .refused(AgentTokenRefusal.archived.message) }
                return .granted
            case .failure(.wrongAgent):
                why = "That token is another agent's."
            case .failure(.expired):
                expired = true
            case .failure(.malformed), .failure(.badSignature):
                break
            case .failure(let refusal):
                why = refusal.message
            }
        }
        return expired ? .expired : .refused(why)
    }

    package func session(of agent: String) -> String {
        agents[Self.key(agent)]?.session ?? Self.key(agent)
    }

    package func conversation(of agent: String) -> (resume: String, cwd: String)? {
        agents[Self.key(agent)].map { ($0.resume, $0.cwd) }
    }

    /// A new token for `agent`: an hour's, as its session.
    package func token(for agent: String) -> String {
        let id = Self.key(agent)
        return tokens.mint(.runnerAgent, session: session(of: id), agent: id)
    }

    package func expiry(of token: String) -> Date? {
        tokens.expiry(of: token)
    }

    package var tokenRefreshLead: TimeInterval { tokens.runnerAgentLifetime / 6 }

    /// Always: the container is the agent's sandbox, and its session gets
    /// Visor's own MCP tools alone.
    package func runsInContainer(_ agent: String) -> Bool { true }

    /// An agent's id as it's kept: in lower case, however its wrapper
    /// spells it back.
    nonisolated static func key(_ agent: String) -> String {
        agent.lowercased()
    }
}
