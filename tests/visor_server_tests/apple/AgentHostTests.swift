// Agents under hosts of their own (visor-agent-host): what the agent says
// reaches the server; a server that lets the host go and connects again is
// sent only what it had not heard, including what was said while it was
// away; and an ended agent takes its host with it.

import Foundation
@testable import VisorAgent
@testable import VisorServer
import VisorServerPOSIX
import Testing

extension ServerTests {
@Suite @MainActor final class AgentHostTests {
    private var hosting: POSIXAgentHosting!
    /// A short folder: a socket's path must fit in 104 bytes, and the
    /// tests' own temporary folder is longer than that.
    private var folder: URL!

    init() async throws {
        TestPlatform.install()
        // In the test bundle's Resources; else (a test binary of Bazel's
        // own) among its runfiles.
        let environment = ProcessInfo.processInfo.environment
        let program = Bundle(for: Self.self).url(forResource: "visor-agent-host", withExtension: nil)?.path
            ?? "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "")/applications/visor_agent_host/visor-agent-host"
        hosting = POSIXAgentHosting(program: program)
        #expect(hosting.problem() == nil, "the host program is built beside the tests")
        folder = URL(fileURLWithPath: "/tmp/vh-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func start(_ script: String) throws -> HostedChild {
        try HostedChild.start(executable: "/bin/sh", arguments: ["-c", script], directory: "/tmp", environment: [:],
                              session: "test", in: folder, memoryLimit: 0, hosting: hosting)
    }

    private func lines(of child: some AgentChild) -> AsyncStream<String> {
        child.output.lines { [$0] }
    }

    @Test func testLinesBothWaysAndAnEndThatTakesTheHost() async throws {
        let child = try start("while read line; do echo \"got $line\"; done")
        var heard = lines(of: child).makeAsyncIterator()
        child.write(["n": 1])
        let first = await heard.next()
        #expect(first == (#"got {"n":1}"#))
        #expect(child.pid > 0)
        #expect(child.nextLine == 1)
        await child.end(grace: .seconds(2))
        #expect(!child.isRunning)
        // The host goes once it has said so.
        for _ in 0..<40 where FileManager.default.fileExists(atPath: child.socket) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!FileManager.default.fileExists(atPath: child.socket))
    }

    @Test func testAServerThatComesBackHearsWhatItMissedOnce() async throws {
        let child = try start("read first; echo \"one $first\"; read second; sleep 1; echo \"two $second\"; read third; echo \"three $third\"")
        var heard = lines(of: child).makeAsyncIterator()
        child.write(["a": 1])
        let one = await heard.next()
        #expect(one == (#"one {"a":1}"#))
        child.write(["b": 2])
        // The server goes before the agent answers; the agent works on.
        try await Task.sleep(for: .milliseconds(200))
        let socket = child.socket, line = child.nextLine
        child.detach()
        try await Task.sleep(for: .seconds(2))

        let picked = await HostedChild.attach(socket: socket, from: line, hosting: hosting)
        let again = try #require(picked)
        #expect(!again.missedLines)
        var resumed = lines(of: again).makeAsyncIterator()
        let two = await resumed.next()
        #expect(two == (#"two {"b":2}"#), "said while no server was there, and not the line heard before")
        again.write(["c": 3])
        let three = await resumed.next()
        #expect(three == (#"three {"c":3}"#))
        let exit = await again.exit.value
        #expect(exit.status == 0)
    }

    @Test func testNothingAnswersWhereNoHostIs() async {
        let gone = await HostedChild.attach(socket: "/tmp/vh-none-\(UUID().uuidString.prefix(6)).sock", from: 0, hosting: hosting)
        #expect(gone == nil)
    }

    @Test func testTheGuardStopsWhatHoldsTooMuchAndSaysSo() async throws {
        // 300 MB held by what the agent runs; the limit is 100 MB.
        let child = try HostedChild.start(
            executable: "/bin/sh",
            arguments: ["-c", "python3 -c 'import time; b = bytearray(300 << 20); b[::4096] = b\"x\" * len(b[::4096]); time.sleep(30)'; echo \"ended $?\""],
            directory: "/tmp", environment: ProcessInfo.processInfo.environment, session: "guard", in: folder,
            memoryLimit: 100 << 20, hosting: hosting)
        var notices = child.notices.makeAsyncIterator()
        let notice = await notices.next()
        #expect(notice?.hasPrefix("Visor stopped") == true, Comment(rawValue: notice ?? "no notice"))
        #expect(notice?.contains("over the session's limit of 0.1 GB") == true, Comment(rawValue: notice ?? ""))
        var heard = lines(of: child).makeAsyncIterator()
        let ended = await heard.next()
        #expect(ended == "ended 143", "the agent lives on; what it ran was stopped")
        await child.end(grace: .seconds(1))
    }

    @Test func testDetachingIsTheSettingUnlessTheEnvironmentSays() {
        var settings = ServerSettings()
        #expect(settings.detachAgents, "on unless turned off")
        // The tests' platform has no host, as Windows has none: off unless told.
        #expect(!VisorServer.detachesAgents(settings, environment: [:]))
        #expect(VisorServer.detachesAgents(settings, environment: ["VISOR_DETACH_AGENT_HOST": "1"]))
        settings.detachAgents = false
        #expect(!VisorServer.detachesAgents(settings, environment: ["VISOR_DETACH_AGENT_HOST": "0"]))
        #expect(VisorServer.detachingSet(in: ["VISOR_DETACH_AGENT_HOST": "false"]) == false)
        #expect(VisorServer.detachingSet(in: ["VISOR_DETACH_AGENT_HOST": "true"]) == true)
        #expect(VisorServer.detachingSet(in: [:]) == nil)
    }

    @Test func testAnAgentThatCannotBeDetachedIsNotStartedAnotherWay() async throws {
        AgentChildren.detach = true
        defer { AgentChildren.detach = false }
        let error = #expect(throws: (any Error).self) {
            try AgentChildren.start(executable: "/bin/cat", arguments: [], directory: "/tmp", environment: [:], session: "s")
        }
        #expect(error?.localizedDescription.contains("VISOR_DETACH_AGENT_HOST=0") == true, Comment(rawValue: error?.localizedDescription ?? ""))
        // Without a session (nothing to pick up again) it is a child.
        let child = try AgentChildren.start(executable: "/bin/cat", arguments: [], directory: "/tmp", environment: [:], session: nil)
        #expect(child is PipedChild)
        await child.end(grace: .seconds(1))
    }
}
}
