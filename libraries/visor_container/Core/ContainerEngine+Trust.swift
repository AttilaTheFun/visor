// agent-proxy's authorities trusted in the Sessions container (docs/containers.md,
// "Claude's credential"): GitHub's and Anthropic's certificates (public,
// never a key), staged each boot on the Visor volume (`sessions/trust/`) and
// shared read-only at /opt/visor/trust: each as a `.crt`, which the guest's
// system trust takes in (Debian's update-ca-certificates, so git, curl and
// the rest take agent-proxy's leaves for those hosts), and all as one file,
// agent-proxy-ca.pem, which Node's TLS (Claude Code's) takes through
// NODE_EXTRA_CA_CERTS. Each is constrained to its own names (AgentProxyCA),
// so trusting it trusts nothing else. Without them (a build or a test that
// gives none, or agent-proxy hasn't made them yet), nothing is shared or
// trusted, and those hosts' TLS fails in the guest.

import Foundation

extension ContainerEngine {
    /// What makes them the guest's system trust: Visor's own put in place of
    /// what was there before, then the system's store made again.
    static let trustCommand = "rm -f /usr/local/share/ca-certificates/visor-*.crt; "
        + #"for f in /opt/visor/trust/*.crt; do [ -e "$f" ] && cp "$f" "/usr/local/share/ca-certificates/visor-${f##*/}"; done; "#
        + "update-ca-certificates --fresh >/dev/null"

    /// The authorities' certificates staged in `layout.trust` for the guest,
    /// each as `authority-<n>.crt` and all as one file; whether there are any.
    func stageAuthorities(_ layout: ContainerLayout) -> Bool {
        let files = FileManager.default
        try? files.removeItem(at: layout.trust)
        let certificates = context.authorities().compactMap { url -> String? in
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----"),
                  !text.contains("PRIVATE KEY") else { return nil }
            return text.hasSuffix("\n") ? text : text + "\n"
        }
        guard !certificates.isEmpty else { return false }
        do {
            try files.createDirectory(at: layout.trust, withIntermediateDirectories: true)
            for (index, pem) in certificates.enumerated() {
                try Data(pem.utf8).write(to: layout.trust.appendingPathComponent("authority-\(index + 1).crt"))
            }
            let bundle = URL(fileURLWithPath: Self.authoritiesInGuest).lastPathComponent
            try Data(certificates.joined().utf8).write(to: layout.trust.appendingPathComponent(bundle))
            return true
        } catch {
            context.log("container: agent-proxy's authorities couldn't be staged: \(Self.describe(error))")
            return false
        }
    }

    /// The staged authorities made the guest's system trust, once it's
    /// booted: said in the log if they couldn't be.
    func trustAuthorities(_ machine: any ContainerMachine, _ layout: ContainerLayout) async {
        let spec = ContainerProcessSpec(id: "trust-\(generation)", arguments: ["/bin/sh", "-c", Self.trustCommand],
                                        log: layout.log(process: "trust"))
        let status: Int32?
        do {
            status = try await Self.run(machine.exec(spec), within: context.checkTimeout)
        } catch {
            context.log("container: agent-proxy's authorities aren't trusted in it: \(Self.describe(error))")
            return
        }
        if status != 0 {
            context.log("container: agent-proxy's authorities aren't trusted in it (update-ca-certificates "
                        + (status.map { "ended \($0)" } ?? "didn't end within \(context.checkTimeout)") + "): git and curl refuse its leaves")
        }
    }
}
