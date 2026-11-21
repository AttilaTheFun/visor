// Each agent's own token (agent_protocol's Job.token): a JWT for
// `visor.runner-agent` (the server's AgentTokens), its `sub` the session
// the agent carries on and its `agent` the agent's id, minted for an hour
// when its job is queued and again when a runner claims it, and refreshed
// over its driver stream before it ends (DriverService: DriverMessage.token).
// The runner hands it to its wrapper in AGENT_TOKEN; every call made for
// the agent shows it (AgentBearer): the wrapper's Connect, Conversation and
// Report, and the runner's Renew and Report. No table of them is kept:
// one is taken while its agent's job is here (waiting or claimed), its
// signature, issuer, audience, agent and scope are right, and its session,
// if it is one yet, isn't archived. Expired, it is refused on the driver
// (a wrapper reconnecting is refused, and its session carried on by a new
// job: VisorServer.resumeAfterExpiredToken) and on the wrapper's reports
// (Started, Progress, Blocked, Completed, Failed: its wrapper's token is
// refreshed over its stream). Only a runner's Renew and its Release report
// take it past its end, and only for AgentTokens.expiredTokenGrace (a
// day) after it: the runner shows the token its claim gave it until it
// reads agent_protocol's RenewResponse.token, the real fix, which Visor
// will send once its pin of agent_protocol has it.

import Foundation
import VisorServer

extension JobQueue: DrivenAgentDirectory {
    /// What a call shown a bearer for `agent` may do: `unknown` when this
    /// dispatcher holds no job of the agent (its job is gone, or was never
    /// here).
    typealias Access = DrivenAgentAccess

    /// The conversation a moved session's agent carries on, and where it
    /// was here.
    func conversation(of agent: String) -> (resume: String, cwd: String)? {
        moves[Self.key(agent)]
    }

    /// A new token for the agent: an hour's, as the session it carries on.
    func token(for agent: String) -> String {
        let id = Self.key(agent)
        return tokens.mint(.runnerAgent, session: session(of: id), agent: id)
    }

    /// How long before its token ends an agent's driver stream is sent a
    /// fresh one: a sixth of its life (ten minutes of an hour).
    var tokenRefreshLead: TimeInterval { tokens.runnerAgentLifetime / 6 }

    /// When `token` ends, if it is one of this server's.
    func expiry(of token: String) -> Date? {
        tokens.expiry(of: token)
    }

    /// Whether this dispatcher holds the agent's job: waiting, or claimed.
    func holds(_ agent: String) -> Bool {
        let id = Self.key(agent)
        return claimed[id] != nil || waiting.contains { $0.agent.uuid == id }
    }

    /// Whether a call for `agent` that shows `bearer` is the agent's.
    func access(_ agent: String, bearer: String?, withinGrace: Bool = false, now: Date = Date()) -> Access {
        access(agent, bearers: bearer.map { [$0] } ?? [], withinGrace: withinGrace, now: now)
    }

    /// Whether a call for `agent` that shows `bearers` is the agent's: one
    /// of them is its token (a runner's renewal shows its own beside it).
    /// `withinGrace`: a runner's Renew or Release, whose runner can't
    /// refresh the token its claim gave it, taking it (or one signed by a
    /// key past its life) up to AgentTokens.expiredTokenGrace past its end.
    func access(_ agent: String, bearers: [String], withinGrace: Bool = false, now: Date = Date()) -> Access {
        let id = Self.key(agent)
        guard holds(id) else { return .unknown }
        let shown = bearers.filter { !$0.isEmpty }
        guard !shown.isEmpty else { return .refused("The call shows no token (authorization: Bearer <Job.token>).") }
        var why = "That token isn't this agent's."
        var expired = false
        // A runner's own token among them isn't a JWT, and is asked apart.
        for bearer in shown where JWT.isShaped(bearer) {
            switch tokens.verify(bearer, as: .runnerAgent, agent: id, scope: .job, now: now, withinGrace: withinGrace) {
            case .success(let claims):
                guard claims.sub == session(of: id) else {
                    why = "That token is another session's."
                    continue
                }
                // nil: a session the server doesn't know (yet: a job whose
                // wrapper hasn't dialled in), or no server (a test of the
                // queue alone). The job itself is held here, and a session
                // that ends takes its jobs with it (forget(session:)).
                if liveSession?(claims.sub) == false { return .refused(AgentTokenRefusal.archived.message) }
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

    /// The runner whose claim on `agent`'s job is held, if one is.
    func holder(of agent: String) -> String? {
        claimed[Self.key(agent)]?.runner
    }
}
