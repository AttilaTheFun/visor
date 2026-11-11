// A server's sockets where VISOR_RUNTIME_DIR says, when its home can't hold
// one (a folder shared into a container over virtiofs: Shireworks' primary
// container's /root). The SSH socket and each agent host's go there; the
// hosts' log stays beside the data. Unset, nothing moves.

import Foundation
@testable import VisorServer
import VisorServerPOSIX
import XCTest

@MainActor
final class RuntimeDirectoryTests: ServerTestCase {
    override func tearDown() async throws {
        VisorServer.socketPathOverride = nil
    }

    func testTheVariableNamesTheSocketsFolder() {
        XCTAssertNil(VisorServer.runtimeDirectory(in: [:]))
        XCTAssertNil(VisorServer.runtimeDirectory(in: ["VISOR_RUNTIME_DIR": "  "]), "empty is unset")
        XCTAssertNil(VisorServer.runtimeDirectory(in: ["XDG_RUNTIME_DIR": "/run/user/1000"]),
                     "not XDG's: a desktop's goes when the user's last session ends")
        XCTAssertEqual(VisorServer.runtimeDirectory(in: ["VISOR_RUNTIME_DIR": "/run/visor"])?.path, "/run/visor")
        XCTAssertEqual(AgentChildren.socketFolder(environment: ["VISOR_RUNTIME_DIR": "/run/visor"]).path, "/run/visor/hosts")
        XCTAssertEqual(AgentChildren.socketFolder(environment: [:]), AgentChildren.folder, "beside the hosts' log, as before")
    }

    /// A real host, its socket in the runtime folder and its log beside the
    /// data: the agent's lines reach the server through it. Where the host
    /// program isn't built beside the tests (a narrower build), skipped.
    func testAnAgentsHostListensInTheRuntimeFolder() async throws {
        let built = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let program = [built, built.deletingLastPathComponent()].map { $0.appendingPathComponent("visor-agent-host").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let program else { throw XCTSkip("visor-agent-host isn't built beside the tests") }
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
        XCTAssertTrue(child.socket.hasPrefix(runtime.path + "/"), child.socket)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("hosts.log").path), "the log beside the data")
        var heard = child.output.lines { [$0] }.makeAsyncIterator()
        child.write(["n": 1])
        let first = await heard.next()
        XCTAssertEqual(first, #"got {"n":1}"#)
        await child.end(grace: .seconds(2))
        XCTAssertFalse(child.isRunning)
    }
}
