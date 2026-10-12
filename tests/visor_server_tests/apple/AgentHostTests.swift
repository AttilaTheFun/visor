// Agents under hosts of their own (visor-agent-host): what the agent says
// reaches the server; a server that lets the host go and connects again is
// sent only what it had not heard, including what was said while it was
// away; and an ended agent takes its host with it.

import Foundation
@testable import VisorServer
import VisorServerPOSIX
import XCTest

@MainActor
final class AgentHostTests: ServerTestCase {
    private var hosting: POSIXAgentHosting!
    /// A short folder: a socket's path must fit in 104 bytes, and the
    /// tests' own temporary folder is longer than that.
    private var folder: URL!

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        let program = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "")/applications/visor_agent_host/visor-agent-host"
        hosting = try XCTUnwrap(POSIXAgentHosting(program: program), "the host program is built beside the tests")
        folder = URL(fileURLWithPath: "/tmp/vh-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func start(_ script: String) throws -> HostedChild {
        try HostedChild.start(executable: "/bin/sh", arguments: ["-c", script], directory: "/tmp", environment: [:],
                              session: "test", in: folder, memoryLimit: 0, hosting: hosting)
    }

    private func lines(of child: some AgentChild) -> AsyncStream<String> {
        child.output.lines { [$0] }
    }

    func testLinesBothWaysAndAnEndThatTakesTheHost() async throws {
        let child = try start("while read line; do echo \"got $line\"; done")
        var heard = lines(of: child).makeAsyncIterator()
        child.write(["n": 1])
        let first = await heard.next()
        XCTAssertEqual(first, #"got {"n":1}"#)
        XCTAssertGreaterThan(child.pid, 0)
        XCTAssertEqual(child.nextLine, 1)
        await child.end(grace: .seconds(2))
        XCTAssertFalse(child.isRunning)
        // The host goes once it has said so.
        for _ in 0..<40 where FileManager.default.fileExists(atPath: child.socket) { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.socket))
    }

    func testAServerThatComesBackHearsWhatItMissedOnce() async throws {
        let child = try start("read first; echo \"one $first\"; read second; sleep 1; echo \"two $second\"; read third; echo \"three $third\"")
        var heard = lines(of: child).makeAsyncIterator()
        child.write(["a": 1])
        let one = await heard.next()
        XCTAssertEqual(one, #"one {"a":1}"#)
        child.write(["b": 2])
        // The server goes before the agent answers; the agent works on.
        try await Task.sleep(for: .milliseconds(200))
        let socket = child.socket, line = child.nextLine
        child.detach()
        try await Task.sleep(for: .seconds(2))

        let picked = await HostedChild.attach(socket: socket, from: line, hosting: hosting)
        let again = try XCTUnwrap(picked)
        XCTAssertFalse(again.missedLines)
        var resumed = lines(of: again).makeAsyncIterator()
        let two = await resumed.next()
        XCTAssertEqual(two, #"two {"b":2}"#, "said while no server was there, and not the line heard before")
        again.write(["c": 3])
        let three = await resumed.next()
        XCTAssertEqual(three, #"three {"c":3}"#)
        let exit = await again.exit.value
        XCTAssertEqual(exit.status, 0)
    }

    func testNothingAnswersWhereNoHostIs() async {
        let gone = await HostedChild.attach(socket: "/tmp/vh-none-\(UUID().uuidString.prefix(6)).sock", from: 0, hosting: hosting)
        XCTAssertNil(gone)
    }

    func testTheGuardStopsWhatHoldsTooMuchAndSaysSo() async throws {
        // 300 MB held by what the agent runs; the limit is 100 MB.
        let child = try HostedChild.start(
            executable: "/bin/sh",
            arguments: ["-c", "python3 -c 'import time; b = bytearray(300 << 20); b[::4096] = b\"x\" * len(b[::4096]); time.sleep(30)'; echo \"ended $?\""],
            directory: "/tmp", environment: ProcessInfo.processInfo.environment, session: "guard", in: folder,
            memoryLimit: 100 << 20, hosting: hosting)
        var notices = child.notices.makeAsyncIterator()
        let notice = await notices.next()
        XCTAssertTrue(notice?.hasPrefix("Visor stopped") == true, notice ?? "no notice")
        XCTAssertTrue(notice?.contains("over the session's limit of 0.1 GB") == true, notice ?? "")
        var heard = lines(of: child).makeAsyncIterator()
        let ended = await heard.next()
        XCTAssertEqual(ended, "ended 143", "the agent lives on; what it ran was stopped")
        await child.end(grace: .seconds(1))
    }
}
