// agent_protocol's AgentDispatcher, served by Visor's server over JobQueue.

import AgentProtocol
import Foundation
import GRPCCore

struct DispatcherService: AgentProtocol_V1_AgentDispatcher.SimpleServiceProtocol {
    let jobs: JobQueue

    func claim(request: AgentProtocol_V1_ClaimRequest, context: ServerContext) async throws -> AgentProtocol_V1_ClaimResponse {
        let wait = Duration.seconds(min(max(Int(request.waitSeconds), 0), 60))
        var answer = AgentProtocol_V1_ClaimResponse()
        if let job = await jobs.claim(request, wait: wait) { answer.job = job }
        return answer
    }

    func report(request: AgentProtocol_V1_JobReport, context: ServerContext) async throws -> AgentProtocol_V1_ReportResponse {
        await jobs.report(request)
        return .init()
    }

    func renew(request: AgentProtocol_V1_RenewRequest, context: ServerContext) async throws -> AgentProtocol_V1_RenewResponse {
        var answer = AgentProtocol_V1_RenewResponse()
        if let expires = await jobs.renew(request.agent) { answer.claimExpires = .init(date: expires) }
        return answer
    }
}
