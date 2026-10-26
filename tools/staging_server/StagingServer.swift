// A Visor server on its own: `bazel run //tools/staging_server -- [port]
// [password]` (7533 and "staging" unless given). It keeps what it keeps in
// a folder under the temporary directory, holds its password in memory, and
// is reached on loopback only — nothing is put in front of it, so the
// installed server's front on 443 is left alone. The agents it starts are
// the real ones. Point the probes at it:
//   VISOR_PORT=7533 VISOR_TOKEN=staging node tools/probes/order.mjs
// Ended with Ctrl-C (or SIGTERM), which ends its agents first.
//
// To lease machines and containers from oss through it: VISOR_STAGING_OSS=
// <oss's address> and VISOR_STAGING_OSS_TOKEN_FILE=<its token's file>
// (containers from the OS Server on this Mac). For sessions in containers,
// VISOR_STAGING_LAN=1 too, so it is reached on the LAN, as an agent in a
// container reaches it for Visor's tools; VISOR_STAGING_IMAGE names the
// image (Visor's latest unless given). tools/probes/container.mjs runs one.

import Foundation
import VisorServer
import VisorServerApple

@main
@MainActor
struct StagingServer {
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        let port = arguments.first.flatMap { UInt16($0) } ?? 7533
        let password = arguments.dropFirst().first ?? "staging"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-staging-\(port)")

        // A Mac's platform, with its password in memory rather than the
        // keychain the installed server uses.
        ServerPlatform.current = .apple(secrets: MemorySecrets())
        // Its log on its own output too, where whoever ran it reads it.
        let systemLog = ServerPlatform.current.log
        ServerPlatform.current.log = { line in
            systemLog(line)
            print(line)
        }
        // Its socket file beside its data, not the installed server's.
        VisorServer.socketPathOverride = "/tmp/visor-staging-\(port).sock"

        let server = VisorServer.staging(port: port, root: root, password: password)
        let environment = ProcessInfo.processInfo.environment
        // No agent host beside a staging build: its agents are its own
        // children (VISOR_DETACH_AGENT_HOST=1, with a host there, says otherwise).
        if environment["VISOR_DETACH_AGENT_HOST"] != "1" { server.settings.detachAgents = false }
        if environment["VISOR_STAGING_LAN"] == "1" { server.settings.lan = true }
        if let image = environment["VISOR_STAGING_IMAGE"], !image.isEmpty { server.settings.containerImage = image }
        if let oss = environment["VISOR_STAGING_OSS"], !oss.isEmpty {
            let file = environment["VISOR_STAGING_OSS_TOKEN_FILE"].map { ($0 as NSString).expandingTildeInPath } ?? ""
            server.setOSSServer(oss, token: try? String(contentsOfFile: file, encoding: .utf8))
            print("Sessions lease machines and containers from oss at \(oss)\(server.ossTokenKept(oss) ? "" : ", once its token is kept")")
        }
        setlinebuf(stdout)
        print("Visor staging server: http://127.0.0.1:\(port) (the socket at /, the API at /api), password \(password)")
        print("Kept in \(root.path)")

        // Its agents go before it does.
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    await server.endAll()
                    exit(0)
                }
            }
            source.resume()
            return source
        }
        withExtendedLifetime(signals) { RunLoop.main.run() }
    }
}
