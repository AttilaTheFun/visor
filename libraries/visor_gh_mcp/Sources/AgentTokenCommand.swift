import Foundation

/// `agent-token token <agent> --owner <owner>` (reviews/agents): it prints
/// the app's installation token and nothing else. It keeps a token until
/// five minutes before its hour ends and hands out none with less left.
public struct AgentTokenCommand: TokenSource {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func token(agent: String, owner: String) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ToolError.failed("agent-token is not at \(path) (agentProxy.gh's agentToken)")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeDirectory()
        let result = try await Run.run(path, ["token", agent, "--owner", owner], environment: environment, timeout: 60)
        guard result.succeeded else {
            throw ToolError.failed("agent-token gave \(agent) no token for \(owner): \(Redact.line(result.errorText))")
        }
        let token = result.output
        guard !token.isEmpty, !token.contains(where: \.isWhitespace),
              token.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0)) })
        else {
            throw ToolError.failed("agent-token printed something that is not a token for \(agent)")
        }
        return token
    }
}
