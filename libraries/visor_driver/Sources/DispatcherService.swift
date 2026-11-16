// agent_protocol's AgentDispatcher, served by Visor's server over JobQueue:
// each call once the server is served (VisorDriver.Listening), so a
// restarted server's queue knows its driven sessions' moves first. A report
// or a renewal is for one agent, and shows that agent's token (Job.token,
// as `authorization: Bearer`; JobQueue+Tokens): the wrapper's reports and
// the runner's renewals and releases alike. A claim shows none: it is how a
// runner is given a job, and its token.

import AgentProtocol
import Foundation
import GRPCCore
import VisorServer

struct DispatcherService: AgentProtocol_V1_AgentDispatcher.ServiceProtocol {
    let listening: VisorDriver.Listening
    let jobs: JobQueue

    func claim(request: ServerRequest<AgentProtocol_V1_ClaimRequest>,
               context: ServerContext) async throws -> ServerResponse<AgentProtocol_V1_ClaimResponse> {
        _ = await listening.ready()
        let wait = Duration.seconds(min(max(Int(request.message.waitSeconds), 0), 60))
        var answer = AgentProtocol_V1_ClaimResponse()
        if let job = await jobs.claim(request.message, wait: wait) { answer.job = job }
        return ServerResponse(message: answer)
    }

    /// A report for an agent whose job is gone is let go, unread; one that
    /// doesn't show its agent's token is refused.
    func report(request: ServerRequest<AgentProtocol_V1_JobReport>,
                context: ServerContext) async throws -> ServerResponse<AgentProtocol_V1_ReportResponse> {
        _ = await listening.ready()
        let agent = request.message.agent.uuid
        switch await jobs.access(agent, bearer: AgentBearer.token(in: request.metadata)) {
        case .granted:
            await jobs.report(request.message)
        case .unknown:
            VisorServer.log("dispatcher: a report for \(agent), whose job it no longer holds: let go")
        case .refused(let why):
            VisorServer.log("dispatcher: a report for \(agent) refused: \(why)")
            throw AgentBearer.refusal(why)
        }
        return ServerResponse(message: .init())
    }

    /// A renewal for an agent whose job is gone is told the claim isn't its
    /// runner's (so the runner ends its agent); one that doesn't show its
    /// agent's token is refused.
    func renew(request: ServerRequest<AgentProtocol_V1_RenewRequest>,
               context: ServerContext) async throws -> ServerResponse<AgentProtocol_V1_RenewResponse> {
        _ = await listening.ready()
        let agent = request.message.agent.uuid
        var answer = AgentProtocol_V1_RenewResponse()
        switch await jobs.access(agent, bearer: AgentBearer.token(in: request.metadata)) {
        case .granted:
            if let expires = await jobs.renew(request.message.agent) { answer.claimExpires = .init(date: expires) }
        case .unknown:
            break
        case .refused(let why):
            VisorServer.log("dispatcher: a renewal for \(agent) refused: \(why)")
            throw AgentBearer.refusal(why)
        }
        return ServerResponse(message: answer)
    }
}
