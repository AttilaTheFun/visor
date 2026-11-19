// How agent-proxy makes its GitHub interceptor (Logan, 2026-11-14:
// MultiPass's GitHub proxy moved in; into Visor from Shireworks' v0.15.1,
// 19 Nov 2026): its authority, kept in `secrets` and made the first time,
// its certificate written where the containers mount it; the gate's rules,
// gate.json's or the standard ones; and the auth token Settings › Agent
// Proxy keeps, read as it is now at each request (ConfiguredGitHubToken).
// Without the authority or the rules there is no interceptor, and GitHub's
// hosts are plain egress; without the token there is one, and each request
// that needs a token is refused.

import Foundation

extension GitHubInterceptor {
    /// The interceptor, or nil (each reason logged). `secrets`: Visor's
    /// secrets, as the host reads them, or a test's. `caCertificate`: where
    /// the authority's certificate is written (mode 644). `gateRules`: a
    /// gate.json, or nil for the standard rules. `token`: the auth token as
    /// kept now (nil: none).
    public static func make(secrets: any AgentProxySecrets, caCertificate: String, gateRules: String?,
                            token: @escaping @Sendable () -> String?, egress: EgressLog?,
                            log: @escaping @Sendable (String) -> Void) -> GitHubInterceptor? {
        let rules: GateRules
        do {
            rules = try gateRules.map(GateRules.load) ?? .standard
        } catch {
            log("github: \(gateRules ?? "") isn't a gate.json (\(error)): GitHub's hosts are plain egress")
            return nil
        }
        let ca: AgentProxyCA
        do {
            ca = try AgentProxyCA.kept(in: secrets)
        } catch {
            log("github: the authority couldn't be read or made (\(error)): GitHub's hosts are plain egress")
            return nil
        }
        do {
            try ca.writeCertificate(to: caCertificate)
        } catch {
            // Containers that don't trust it fail their TLS to GitHub: said, and opened all the same.
            log("github: the authority's certificate couldn't be written to \(caCertificate): \(error)")
        }
        do {
            let interceptor = try GitHubInterceptor(gate: GitHubGate(rules: rules), ca: ca, tokens: ConfiguredGitHubToken(current: token),
                                                    egress: egress, log: log)
            log("github: GitHub's hosts are opened with the authority in \(caCertificate), "
                + "by \(gateRules.map { "the rules of \($0)" } ?? "the standard rules")"
                + (token()?.isEmpty == false ? ", with the auth token" : "; no auth token yet (agent-proxy secret-set github-token): what needs one is refused"))
            return interceptor
        } catch {
            log("github: no TLS for GitHub (\(error)): GitHub's hosts are plain egress")
            return nil
        }
    }
}
