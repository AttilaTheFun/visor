// A Visor server on its own: `bazel run //tools/staging_server -- [port]
// [password]` (7533 and "staging" unless given). It keeps what it keeps in
// a folder under the temporary directory, holds its password in memory, and
// is reached on loopback only — nothing is put in front of it, so the
// installed server's front on 443 is left alone. The agents it starts are
// the real ones. Point the probes at it:
//   VISOR_PORT=7533 VISOR_TOKEN=staging node tools/probes/order.mjs
// Ended with Ctrl-C (or SIGTERM), which ends its agents first.

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

        let server = VisorServer.staging(port: port, root: root, password: password)
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
