// agent_protocol's AgentDispatcher, served by Visor's server over JobQueue:
// each call once the server is served (VisorDriver.Listening), so a
// restarted server's queue knows its driven sessions' moves first. A report
// or a renewal is for one agent, and shows that agent's token (Job.token,
// as `authorization: Bearer`; JobQueue+Tokens): the wrapper's reports and
// the runner's renewals and releases alike. A claim shows the runner's own
// token (RunnerTokens), minted for the name it claims as: required once
// the server's `runnerTokensRequired` is on, and a wrong one refused
// whether or not. A runner token shown beside an agent's, on a renewal or
// a release, must be the runner's that holds the claim.

import AgentProtocol
import Foundation
import GRPCCore
import VisorServer

struct DispatcherService: AgentProtocol_V1_AgentDispatcher.ServiceProtocol {
    let listening: VisorDriver.Listening
    let jobs: JobQueue

    func claim(request: ServerRequest<AgentProtocol_V1_ClaimRequest>,
               context: ServerContext) async throws -> ServerResponse<AgentProtocol_V1_ClaimResponse> {
        let server = await listening.ready()
        try await admitClaim(by: request.message.runner, AgentBearer.tokens(in: request.metadata), server)
        let wait = Duration.seconds(min(max(Int(request.message.waitSeconds), 0), 60))
        var answer = AgentProtocol_V1_ClaimResponse()
        if let job = await jobs.claim(request.message, wait: wait) { answer.job = job }
        return ServerResponse(message: answer)
    }

    /// A report for an agent whose job is gone is let go, unread; one that
    /// doesn't show its agent's token is refused.
    func report(request: ServerRequest<AgentProtocol_V1_JobReport>,
                context: ServerContext) async throws -> ServerResponse<AgentProtocol_V1_ReportResponse> {
        let server = await listening.ready()
        let agent = request.message.agent.uuid
        let bearers = AgentBearer.tokens(in: request.metadata)
        switch await jobs.access(agent, bearers: bearers) {
        case .granted:
            try await runnerMatches(agent, bearers, server, "a report")
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
        let server = await listening.ready()
        let agent = request.message.agent.uuid
        var answer = AgentProtocol_V1_RenewResponse()
        let bearers = AgentBearer.tokens(in: request.metadata)
        switch await jobs.access(agent, bearers: bearers) {
        case .granted:
            try await runnerMatches(agent, bearers, server, "a renewal")
            if let expires = await jobs.renew(request.message.agent) { answer.claimExpires = .init(date: expires) }
        case .unknown:
            break
        case .refused(let why):
            VisorServer.log("dispatcher: a renewal for \(agent) refused: \(why)")
            throw AgentBearer.refusal(why)
        }
        return ServerResponse(message: answer)
    }

    /// Refused when the claim doesn't show `runner`'s token, and must, or
    /// shows one that isn't `runner`'s (RunnerTokens).
    @MainActor
    private func admitClaim(by runner: String, _ bearers: [String], _ server: VisorServer) throws {
        let admission = server.runnerTokens.admit(claimBy: runner, bearers: bearers, required: server.settings.runnerTokensRequired)
        if let refusal = AgentBearer.refusal(admission) {
            VisorServer.log("dispatcher: a claim as \(runner) refused: \(refusal.message)")
            throw refusal
        }
    }

    /// Refused when a runner token among `bearers` isn't the one whose
    /// runner holds `agent`'s claim.
    @MainActor
    private func runnerMatches(_ agent: String, _ bearers: [String], _ server: VisorServer, _ what: String) throws {
        if let refusal = AgentBearer.refusal(server.runnerTokens.admit(callFor: jobs.holder(of: agent), bearers: bearers)) {
            VisorServer.log("dispatcher: \(what) for \(agent) refused: \(refusal.message)")
            throw refusal
        }
    }
}
