// The Claude credential of the Sessions container's agents (docs/containers.md,
// "Claude's credential"): a `claude setup-token` token, pasted into Settings ›
// Sessions Container and kept as agent-proxy's secret
// (`agent-proxy/claude/oauth-token`), which the Anthropic interceptor attaches
// to each request to api.anthropic.com (within a minute of its being set,
// without a restart). The containers never see it: their agents have a
// placeholder (`CLAUDE_CODE_OAUTH_TOKEN=visor-agent-proxy`) the proxy
// replaces.
//
// - `POST /api/container/claude {text}`: kept, once its shape is a
//   setup-token's (`sk-ant-oat…`), else refused, saying so;
// - `DELETE /api/container/claude`: removed (Sign Out).
//
// Each an admin's, as every REST route is, and each answered with how the
// container stands (`claudeCredential`, its presence alone). The credential
// is never answered, logged, or kept anywhere but the server's secrets.

import Foundation
import VisorProtocol

extension VisorServer {
    /// Where the credential is kept with the server's secrets.
    nonisolated static var claudeCredentialKey: String { AgentProxySettings.secretKey(AgentProxySettings.claudeTokenName) }

    /// Whether agent-proxy keeps a Claude credential now.
    var hasClaudeCredential: Bool {
        if case .found(let value) = Self.secrets.lookup(Self.claudeCredentialKey) {
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    /// `POST` or `DELETE /api/container/claude`.
    func routeClaudeCredential(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        if request.method == "DELETE" {
            Self.secrets.set(Self.claudeCredentialKey, nil)
            Self.log("the Sessions container's Claude credential removed")
        } else {
            let token = (Envelope.decodeBody(request.body).text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = ClaudeCredential.problem(token) {
                return respond(HTTPResponse(400, Envelope.error(problem).encoded()))
            }
            Self.secrets.set(Self.claudeCredentialKey, token)
            guard hasClaudeCredential else {
                return respond(HTTPResponse(500, Envelope.error("The Claude credential couldn't be kept with this computer's secrets.").encoded()))
            }
            Self.log("the Sessions container's Claude credential set: agent-proxy attaches it within a minute")
        }
        Task {
            let status = await containerStatus { await $0.status() }
            respond(.json(status.json.encoded()))
        }
    }

    /// The environment of Claude Code in the container, its agents' and the
    /// server's own `claude -p` there: its Claude folder on Sessions
    /// (`<sessions>/.claude`), the credential's placeholder, which
    /// agent-proxy replaces, gh's placeholder token, which agent-proxy's
    /// GitHub gate takes off (and sends its own token in its place, or none
    /// for a read when none is configured), and agent-proxy's authorities
    /// for Node's TLS (the engine's ContainerEngine.authoritiesInGuest; the
    /// system's trust has them too). With `git`, git's author and committer
    /// (VisorServer+ContainerGitIdentity): the agents' alone.
    nonisolated static func containerClaudeEnvironment(sessions: String, git: ContainerGitIdentity? = nil) -> [String: String] {
        ["CLAUDE_CONFIG_DIR": sessions + "/.claude",
         "CLAUDE_CODE_OAUTH_TOKEN": ClaudeCredential.placeholder,
         "GH_TOKEN": containerGitHubPlaceholder,
         "NODE_EXTRA_CA_CERTS": containerAuthoritiesInGuest].merging(git?.environment ?? [:]) { kept, _ in kept }
    }

    /// gh's token in the container: a placeholder, never a credential, so
    /// that gh sends its requests at all (without one it asks to log in).
    /// agent-proxy's GitHub gate takes off whatever authorization comes.
    nonisolated static let containerGitHubPlaceholder = "visor-agent-proxy"

    /// agent-proxy's authorities' certificates in the container, one file
    /// (ContainerEngine.authoritiesInGuest, which carries them in).
    nonisolated static let containerAuthoritiesInGuest = "/opt/visor/trust/agent-proxy-ca.pem"

    /// What `/login` in a session placed in the container is told: its Claude
    /// is signed in through agent-proxy, not in the container.
    nonisolated static let containerSignIn = "This session runs in the Sessions container, whose agents reach Claude through Visor's agent-proxy: "
        + "Sign In to Claude in Settings › Sessions Container (on this computer's page in Visor's Settings) with a "
        + "`claude setup-token` token. No sign-in happens in the container."
}
