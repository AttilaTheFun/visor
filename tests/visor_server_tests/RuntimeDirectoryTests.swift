// A server's sockets where VISOR_RUNTIME_DIR says, when its home can't hold
// one (a folder shared into a container over virtiofs: Shireworks' primary
// container's /root). The SSH socket and each agent host's go there; the
// hosts' log stays beside the data. Unset, nothing moves.

import Foundation
@testable import VisorAgent
@testable import VisorServer
import VisorServerPOSIX
import Testing

extension ServerTests {
@Suite @MainActor final class RuntimeDirectoryTests {
    init() { TestPlatform.install() }

    isolated deinit {
        VisorServer.socketPathOverride = nil
    }

    @Test func testTheVariableNamesTheSocketsFolder() {
        #expect(VisorServer.runtimeDirectory(in: [:]) == nil)
        #expect(VisorServer.runtimeDirectory(in: ["VISOR_RUNTIME_DIR": "  "]) == nil, "empty is unset")
        #expect(VisorServer.runtimeDirectory(in: ["XDG_RUNTIME_DIR": "/run/user/1000"]) == nil, "not XDG's: a desktop's goes when the user's last session ends")
        #expect((VisorServer.runtimeDirectory(in: ["VISOR_RUNTIME_DIR": "/run/visor"])?.path) == "/run/visor")
        #expect(AgentChildren.socketFolder(environment: ["VISOR_RUNTIME_DIR": "/run/visor"]).path == "/run/visor/hosts")
        #expect(AgentChildren.socketFolder(environment: [:]) == AgentChildren.folder, "beside the hosts' log, as before")
    }

    /// A real host, its socket in the runtime folder and its log beside the
    /// data: the agent's lines reach the server through it. Where the host
    /// program isn't built beside the tests (a narrower build), skipped.
    @Test func testAnAgentsHostListensInTheRuntimeFolder() async throws {
        let built = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let program = [built, built.deletingLastPathComponent()].map { $0.appendingPathComponent("visor-agent-host").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let program else { try Test.cancel("visor-agent-host isn't built beside the tests") }
        let hosting = POSIXAgentHosting(program: program)
        // Short folders: a socket's path must fit in 104 bytes.
        let tag = String(UUID().uuidString.prefix(8))
        let data = URL(fileURLWithPath: "/tmp/vd-" + tag, isDirectory: true)
        let runtime = URL(fileURLWithPath: "/tmp/vr-" + tag, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: data)
            try? FileManager.default.removeItem(at: runtime)
        }
        let child = try HostedChild.start(executable: "/bin/sh", arguments: ["-c", "while read line; do echo \"got $line\"; done"],
                                          directory: "/tmp", environment: [:], session: "test", in: data, socketsIn: runtime,
                                          memoryLimit: 0, hosting: hosting)
        #expect(child.socket.hasPrefix(runtime.path + "/"), Comment(rawValue: child.socket))
        #expect(FileManager.default.fileExists(atPath: data.appendingPathComponent("hosts.log").path), "the log beside the data")
        var heard = child.output.lines { [$0] }.makeAsyncIterator()
        child.write(["n": 1])
        let first = await heard.next()
        #expect(first == (#"got {"n":1}"#))
        await child.end(grace: .seconds(2))
        #expect(!child.isRunning)
    }
}
}
