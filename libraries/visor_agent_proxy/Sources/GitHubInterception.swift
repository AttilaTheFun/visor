// How agent-proxy makes its GitHub interceptor (Logan, 2026-11-14:
// MultiPass's GitHub proxy moved in; into Visor from Shireworks' v0.15.1,
// 19 Nov 2026): its authority, kept in `secrets` and made the first time,
// its certificate written where the containers mount it; the gate's rules,
// gate.json's or the standard ones; and the GitHub credential, read as it
// is kept now at each request (PreferredGitHubToken): the GitHub App's
// installation tokens when its key and id are kept (GitHubAppTokens), else
// the auth token Settings › Agent Proxy keeps (ConfiguredGitHubToken).
// Without the authority or the rules there is no interceptor, and GitHub's
// hosts are plain egress; without a credential there is one, and each
// request that needs a token is refused.

import Foundation

extension GitHubInterceptor {
    /// The interceptor, or nil (each reason logged). `secrets`: Visor's
    /// secrets, as the host reads them, or a test's. `caCertificate`: where
    /// the authority's certificate is written (mode 644). `gateRules`: a
    /// gate.json, or nil for the standard rules. `token`: the auth token as
    /// kept now (nil: none). `app`: the GitHub App's secrets as kept now
    /// (nil: its key or its id isn't), which come before the auth token.
    public static func make(secrets: any AgentProxySecrets, caCertificate: String, gateRules: String?,
                            token: @escaping @Sendable () -> String?, app: @escaping @Sendable () -> GitHubAppSecrets? = { nil },
                            egress: EgressLog?, log: @escaping @Sendable (String) -> Void) -> GitHubInterceptor? {
        make(secrets: secrets, caCertificate: caCertificate, gateRules: gateRules, token: token, app: app, appAPI: GitHubAppAPI(),
             egress: egress, log: log)
    }

    /// The same, the App's calls answered by `appAPI`: GitHub's, or a
    /// test's stand-in.
    static func make(secrets: any AgentProxySecrets, caCertificate: String, gateRules: String?,
                     token: @escaping @Sendable () -> String?, app: @escaping @Sendable () -> GitHubAppSecrets?,
                     appAPI: any GitHubAppCalling, egress: EgressLog?, log: @escaping @Sendable (String) -> Void) -> GitHubInterceptor? {
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
            let appTokens = GitHubAppTokens(rules: rules, api: appAPI, log: log)
            let tokens = PreferredGitHubToken(app: appTokens, appSecrets: app, configured: ConfiguredGitHubToken(current: token))
            let interceptor = try GitHubInterceptor(gate: GitHubGate(rules: rules), ca: ca, tokens: tokens, egress: egress, log: log)
            let appSecrets = app()
            log("github: GitHub's hosts are opened with the authority in \(caCertificate), "
                + "by \(gateRules.map { "the rules of \($0)" } ?? "the standard rules")"
                + (appSecrets != nil ? ", with the GitHub App's installation tokens"
                    : token()?.isEmpty == false ? ", with the auth token"
                    : "; no auth token yet (agent-proxy secret-set github-token, or github-app/key and github-app/id): what needs one is refused"))
            // The App's lines (its bot's too), or what's wrong with its secrets, said now rather than at the first request.
            if let appSecrets { Task { await appTokens.prepare(appSecrets) } }
            return interceptor
        } catch {
            log("github: no TLS for GitHub (\(error)): GitHub's hosts are plain egress")
            return nil
        }
    }
}
