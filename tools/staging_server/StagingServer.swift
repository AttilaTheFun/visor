// A Visor server on its own: `bazel run //tools/staging_server -- [port]
// [password]` (7533 and "staging" unless given). It keeps what it keeps in
// a folder under the temporary directory, holds its password in memory, and
// is reached on loopback only — nothing is put in front of it, so the
// installed server's front on 443 is left alone. The agents it starts are
// the real ones. Point the probes at it:
//   VISOR_PORT=7533 VISOR_TOKEN=staging node tools/probes/order.mjs
// Ended with Ctrl-C (or SIGTERM), which ends its agents first.
//
// To try sessions in containers on oss: VISOR_STAGING_OSS=<oss's address>
// and VISOR_STAGING_OSS_TOKEN_FILE=<its token's file>; with
// VISOR_STAGING_LAN=1 it is reached on the LAN too, as an agent in a
// container reaches it for Visor's tools.

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
        if environment["VISOR_STAGING_LAN"] == "1" { server.settings.lan = true }
        if let oss = environment["VISOR_STAGING_OSS"], !oss.isEmpty {
            server.settings.ossServer = oss
            let file = environment["VISOR_STAGING_OSS_TOKEN_FILE"].map { ($0 as NSString).expandingTildeInPath } ?? ""
            server.setOSSToken(try? String(contentsOfFile: file, encoding: .utf8))
            print("Sessions can start in containers on oss at \(oss)\(server.containersAvailable ? "" : ", once its token is kept"); they reach this server at \(server.containerServerURL)")
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
