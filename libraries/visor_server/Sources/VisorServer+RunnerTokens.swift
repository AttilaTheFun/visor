// The runners' tokens over REST (RunnerTokens), for the computer's owner:
// the password, a token `hello` gave, the admin token, or a trusted
// connection; never an agent's token, which the REST side refuses
// (authorized: an agent that could mint one could claim its own jobs, or
// revoke another runner's).
//
//   GET    /api/runners/tokens            {required, runners: [{runner, created, own}]}
//   POST   /api/runners/tokens {runner}   {runner, token, created, replaced}: the token shown this once
//   PUT    /api/runners/tokens {required} as GET: whether Claim must show one
//   DELETE /api/runners/tokens/<runner>   {runner, revoked: true}; 404 for a runner with none

import Foundation
import VisorProtocol

extension VisorServer {
    /// `/api/runners/tokens…`, by method.
    func restRunnerTokens(_ call: RESTCall) -> HTTPResponse {
        return switch (call.request.method, call.parts.count) {
        case ("GET", 2): restListRunnerTokens()
        case ("POST", 2): restMintRunnerToken(call)
        case ("PUT", 2): restRequireRunnerTokens(call)
        case ("DELETE", 3): restRevokeRunnerToken(call)
        default: HTTPResponse(404, "{\"error\":\"not found\"}")
        }
    }

    private func restListRunnerTokens() -> HTTPResponse {
        let runners: [JSONValue] = runnerTokens.listed.map { listed in
            var fields: [String: JSONValue] = ["runner": .string(listed.runner), "created": .string(listed.created)]
            if listed.own { fields["own"] = .bool(true) }
            return .object(fields)
        }
        return .json(JSONValue.object(["required": .bool(settings.runnerTokensRequired), "runners": .array(runners)]).encoded())
    }

    private func restMintRunnerToken(_ call: RESTCall) -> HTTPResponse {
        let runner = parseJSON(call.request.body)?["runner"].string ?? ""
        if let problem = RunnerTokens.problem(withName: runner) { return HTTPResponse(400, Envelope.error(problem).encoded()) }
        let made = runnerTokens.mint(for: runner)
        return .json(JSONValue.object(["runner": .string(runner), "token": .string(made.token), "created": .string(made.created),
                                       "replaced": .bool(made.replaced)]).encoded())
    }

    private func restRequireRunnerTokens(_ call: RESTCall) -> HTTPResponse {
        guard let required = parseJSON(call.request.body)?["required"].bool else {
            return HTTPResponse(400, Envelope.error("Send {\"required\": true} or {\"required\": false}.").encoded())
        }
        if required != settings.runnerTokensRequired {
            settings.runnerTokensRequired = required
            Self.log("runner tokens: \(required ? "required on Claim from now on" : "no longer required on Claim")")
        }
        return restListRunnerTokens()
    }

    private func restRevokeRunnerToken(_ call: RESTCall) -> HTTPResponse {
        let runner = call.parts[2].removingPercentEncoding ?? call.parts[2]
        guard runnerTokens.revoke(runner) else {
            return HTTPResponse(404, Envelope.error("\(runner) has no runner token.").encoded())
        }
        return .json(JSONValue.object(["runner": .string(runner), "revoked": .bool(true)]).encoded())
    }
}
