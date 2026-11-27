import Foundation

// The audit of dispatches on main (NCH's conditions for agents' release
// proposals, 26 Nov 2026): every dispatch on a repository's default branch,
// or on a protected branch's name (main, master), let through or refused,
// is one line of agent-proxy's log (the server's, where it runs inside it):
//
//     github: dispatch on main: container:<lease> agent <id|unnamed>, <owner/repo> <path|workflow <id>> on <ref>, inputs <name=value …|none>: allowed
//
// or `: refused: <why>`, `: failed: <why>`. The container is the relay's
// lease, and the agent the one it claims to be (its X-Agent-ID). An input's
// value is written only when it is one gate.json's mainDispatch lists for
// that input; another is its length alone, so that nothing an agent sends
// in one (a secret, say) reaches the log. Never a header, a token or a body
// past these. A dispatch on an agent's own branch is the egress log's line
// alone, as every request is.

extension GitHubInterceptor {
    /// A dispatch, as its request names it (`POST
    /// /repos/{o}/{r}/actions/workflows/{id}/dispatches`), read leniently:
    /// what the audit says of one the gate refused too.
    struct DispatchRequest: Equatable {
        var repository: String
        var workflow: String
        var ref: String
        var inputs: [String: String]
    }

    static func dispatchRequest(_ request: GateRequest) -> DispatchRequest? {
        guard request.method == "POST", request.host.lowercased() == "api.github.com", let segments = GitHubGate.segments(request.path),
              segments.count == 7, segments[0] == "repos", segments[3] == "actions", segments[4] == "workflows", segments[6] == "dispatches"
        else { return nil }
        let body = request.body.flatMap { GateJSON.parse($0)?.object } ?? [:]
        var inputs: [String: String] = [:]
        for (name, value) in body["inputs"]?.object ?? [:] { inputs[name] = value.string ?? "" }
        return DispatchRequest(repository: segments[1] + "/" + segments[2], workflow: segments[5], ref: body["ref"]?.string ?? "", inputs: inputs)
    }

    /// The audit's line for `request`, if it is a dispatch on main, as it
    /// settled.
    func audit(_ request: GateRequest, finding: GateChecker.DispatchFinding?, settled: Settled, caller: EgressProxy.Caller) {
        guard let dispatch = Self.dispatchRequest(request) else { return }
        let named = GateChecker.branchName(dispatch.ref)
        let onMain = finding?.onDefaultBranch == true || named.lowercased() == "main" || gate.rules.protects(named, defaultBranch: nil)
        guard onMain else { return }
        let outcome: String
        switch settled {
        case .forward, .anonymous: outcome = "allowed"
        case .refuse(let reason): outcome = "refused: \(reason)"
        case .fail(let reason): outcome = "failed: \(reason)"
        }
        log(Self.auditLine(dispatch, workflowPath: finding?.workflowPath, rules: gate.rules, caller: caller, outcome: outcome))
    }

    static func auditLine(_ dispatch: DispatchRequest, workflowPath: String?, rules: GateRules, caller: EgressProxy.Caller, outcome: String) -> String {
        // The values the repository's mainDispatch lists for each input: of its workflow, when it's known, else of any of its.
        var listed: [String: Set<String>] = [:]
        for (key, inputs) in rules.mainDispatch.workflows {
            guard case let (repository, path)? = GateRules.qualified(key), repository.lowercased() == dispatch.repository.lowercased(),
                  workflowPath == nil || workflowPath == path else { continue }
            for (name, values) in inputs { listed[name, default: []].formUnion(values) }
        }
        let inputs = dispatch.inputs.keys.sorted().map { name -> String in
            let value = dispatch.inputs[name] ?? ""
            guard GateRules.isInputName(name) else { return "(an input's name, not written)" }
            return listed[name]?.contains(value) == true ? "\(name)=\(value)" : "\(name)=(\(value.count) characters, not written)"
        }
        let workflow = workflowPath ?? "workflow \(shown(dispatch.workflow))"
        let agent = caller.agent.map { "agent \($0)" } ?? "agent unnamed"
        return "github: dispatch on main: \(shown(caller.session)) \(shown(agent)), \(shown(dispatch.repository)) \(workflow) on \(shown(dispatch.ref)), "
            + "inputs \(inputs.isEmpty ? "none" : inputs.joined(separator: " ")): \(shown(outcome))"
    }

    /// Text as one line of the log: no control character or line break, at
    /// most 300 characters.
    static func shown(_ text: String) -> String {
        let breaking: Set<UInt32> = [0x7F, 0x85, 0x2028, 0x2029]
        let kept = String(text.unicodeScalars.map { scalar -> Character in scalar.value < 0x20 || breaking.contains(scalar.value) ? "?" : Character(scalar) })
        return kept.count > 300 ? String(kept.prefix(300)) + "…" : kept
    }
}
