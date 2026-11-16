// A wrapped agent's permission prompts as Visor shows them, and the
// person's answers as its wrapper takes them (agent_protocol's
// ApprovalRequest and Approval): the same prompt and the same answers as a
// session's own MCP server's `approve` (VisorMCPBridge's MCPBridge.decision).

import AgentProtocol
import Foundation
import VisorProtocol

extension DrivenProcess {
    /// The prompt as the session shows it: an AskUserQuestion with its
    /// questions (answered, not allowed), any other tool with its line.
    static func prompt(_ request: AgentProtocol_V1_ApprovalRequest) -> ApprovalRequest {
        let tool = request.tool.isEmpty ? "tool" : request.tool
        let input = parseJSON(request.inputJson) ?? .null
        if tool == "AskUserQuestion", let asked = input["questions"].array {
            let questions = asked.compactMap(AgentQuestion.init(json:))
            if !questions.isEmpty {
                return ApprovalRequest(id: request.id, tool: tool, summary: questions[0].question, questions: questions)
            }
        }
        return ApprovalRequest(id: request.id, tool: tool, summary: request.summary)
    }

    /// The answer the wrapper gives Claude: allowed, with an
    /// AskUserQuestion's answers in its input; or denied, and why.
    static func approval(of request: AgentProtocol_V1_ApprovalRequest, allow: Bool,
                         answers: [String: String]?) -> AgentProtocol_V1_Approval {
        var approval = AgentProtocol_V1_Approval()
        approval.requestID = request.id
        approval.allow = allow
        guard allow else {
            approval.reason = request.tool == "AskUserQuestion" ? "The user did not answer from Visor." : "The user denied this from Visor."
            return approval
        }
        // The input as asked, unless answers change it (the wrapper's own
        // otherwise).
        if let answers, var input = parseJSON(request.inputJson)?.object {
            input["answers"] = .object(answers.mapValues { .string($0) })
            approval.updatedInputJson = JSONValue.object(input).encoded()
        }
        return approval
    }
}
