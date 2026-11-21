import Foundation

public struct Toolbox: Sendable {
    public let tools: [Tool]

    public init() {
        tools = Self.catalog + Self.collaboration + Self.merging + Self.reruns
    }

    public func tool(named name: String) -> Tool? {
        tools.first { $0.name == name }
    }

    public func call(_ tool: Tool, arguments: JSON, caller: Caller, rules: RepoRules, services: Services) async -> ToolOutcome {
        let note = CallNote()
        if let repo = arguments["repo"]?.stringValue {
            note.repo = Redact.line(repo, limit: 120).replacingOccurrences(of: " ", with: "_")
        }
        do {
            let parsed = try Arguments.parse(arguments, tool.params, tool: tool.name)
            let github = GitHub(transport: services.transport, tokens: services.tokens, agent: caller.agent)
            let context = ToolContext(caller: caller, rules: rules, github: github, services: services, note: note)
            let text = try await tool.run(parsed, context)
            return ToolOutcome(text: Redact.secrets(in: text), isError: false, repo: note.repo ?? "-", logOutcome: "ok")
        } catch let error as ToolError {
            return ToolOutcome(text: Redact.line(error.text, limit: 2000), isError: true, repo: note.repo ?? "-",
                               logOutcome: Redact.line(error.outcome, limit: 300))
        } catch {
            let failure = ToolError.failed(String(describing: error))
            return ToolOutcome(text: Redact.line(failure.text, limit: 2000), isError: true, repo: note.repo ?? "-",
                               logOutcome: Redact.line(failure.outcome, limit: 300))
        }
    }
}
