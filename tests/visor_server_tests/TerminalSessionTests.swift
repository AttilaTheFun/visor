// Terminal sessions: the computer's shell on a PTY, in the session's
// folder, typed into and drawn; started when a window takes it and kept
// when another window does; nothing of a chat about it — no transcript,
// no turns, no messages from agents.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

/// What a shell has drawn, as text.
@MainActor
private final class Screen {
    private(set) var text = ""
    private var reading: Task<Void, Never>?

    init(_ events: AsyncStream<AgentEvent>) {
        reading = Task { [weak self] in
            for await event in events {
                if case .tty(let data) = event { self?.text += String(decoding: data, as: UTF8.self) }
            }
        }
    }

    /// Whether `words` are drawn within `seconds`.
    func shows(_ words: String, within seconds: Double = 10) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if text.contains(words) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return text.contains(words)
    }
}

@MainActor
final class TerminalSessionTests: XCTestCase {
    private var folder: String!

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        folder = root.path
    }

    /// Lines go in and their output comes out; the shell runs in the
    /// session's folder, without the server's own secrets; when it exits
    /// the window is told, and a key brings a new one.
    func testAShellIsTypedIntoAndDraws() async throws {
        setenv("VISOR_TOKEN", "not-for-the-shell", 1)
        defer { unsetenv("VISOR_TOKEN") }
        let shell = ShellProcess(cwd: folder, shell: "/bin/sh")
        let screen = Screen(shell.events)
        shell.resize(cols: 80, rows: 24)
        try shell.start()
        XCTAssertNotNil(shell.processID)

        try shell.send("echo visor-$((40 + 2))")
        let ran = await screen.shows("visor-42")
        XCTAssertTrue(ran, screen.text)
        try shell.send("pwd; echo token=${VISOR_TOKEN-unset}")
        let inFolder = await screen.shows((folder as NSString).lastPathComponent)
        XCTAssertTrue(inFolder, "the session's folder: \(screen.text)")
        let clean = await screen.shows("token=unset")
        XCTAssertTrue(clean, "the server's token stays out of the shell: \(screen.text)")

        // The terminal is the shell's controlling terminal: a job runs in
        // the foreground, and Ctrl-C ends it at once. (Under the test runner
        // a shell gets one even without TIOCSCTTY; a server started by
        // launchd does not, which the lifecycle probe's TERMINAL=1 run
        // checks against a real server.)
        try shell.send("ps -o tty= -p $$ | sed 's/^/tty=/'")
        let hasTerminal = await screen.shows("tty=ttys")
        XCTAssertTrue(hasTerminal, "a controlling terminal: \(screen.text)")
        try shell.send("sleep 30; echo slept")
        try await Task.sleep(for: .milliseconds(500))
        shell.interrupt()
        try shell.send("echo interrupted-$((1 + 1))")
        let interrupted = await screen.shows("interrupted-2", within: 5)
        XCTAssertTrue(interrupted, "Ctrl-C ended the sleep: \(screen.text)")
        XCTAssertFalse(screen.text.contains("slept\r"), "the line after the sleep did not run")

        shell.write(Data("exit\r".utf8))
        let exited = await screen.shows("The shell exited")
        XCTAssertTrue(exited, screen.text)
        XCTAssertNil(shell.processID)
        shell.write(Data("x".utf8))
        XCTAssertNotNil(shell.processID, "a key starts a new shell")
        try shell.send("echo again-$((1 + 1))")
        let again = await screen.shows("again-2")
        XCTAssertTrue(again, screen.text)

        await shell.end(within: .seconds(2))
        XCTAssertNil(shell.processID)
    }

    /// Over the protocol: nothing runs until a window takes the session;
    /// a line sent is typed in and nothing is written down; another window
    /// taking it gets the same shell; a chat has no terminal to take; and
    /// agents cannot message a terminal.
    func testATerminalSessionOverTheProtocol() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("visor-terminal-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        VisorServer.storeRoot = store
        VisorServer.secrets = MemorySecrets()
        let server = VisorServer(port: 7995)
        server.harnesses = AgentHarnesses([ClaudeHarness(kind: .claude, tool: "claude", models: []), ShellHarness(shell: "/bin/sh")])

        server.perform(.start(id: "T", agent: .shell, cwd: folder, title: "", skipPermissions: true), from: nil)
        let record = try XCTUnwrap(server.session("T"))
        XCTAssertEqual(record.info.title, "Terminal 1")
        XCTAssertNil(record.process.processID, "nothing runs until a window takes it")

        var take = Envelope(type: "mode")
        take.session = "T"
        take.mode = "tui"
        take.controller = "phone"
        take.cols = 80
        take.rows = 24
        server.perform(take, from: nil)
        XCTAssertEqual(record.info.mode, .tui(controller: "phone", cols: 80, rows: 24))
        let pid = try XCTUnwrap(record.process.processID)

        server.perform(.send(session: "T", text: "echo shell-$((2 * 21))"), from: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !String(decoding: record.scrollback, as: UTF8.self).contains("shell-42") {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(String(decoding: record.scrollback, as: UTF8.self).contains("shell-42"))
        XCTAssertTrue(record.entries.isEmpty, "nothing is written down")
        XCTAssertFalse(record.info.busy, "a terminal has no turns")

        take.controller = "mac"
        take.cols = 120
        take.rows = 40
        server.perform(take, from: nil)
        XCTAssertEqual(record.info.mode.controller, "mac")
        XCTAssertEqual(record.process.processID, pid, "the same shell, drawn for the other window")

        server.perform(.start(id: "C", agent: .claude, cwd: folder, title: "", skipPermissions: true), from: nil)
        var chat = take
        chat.session = "C"
        server.perform(chat, from: nil)
        XCTAssertEqual(server.session("C")?.info.mode, .chat, "a chat has no terminal to take")

        var ask = Envelope(type: "agent")
        ask.token = server.agentToken
        ask.client = "C"
        ask.mode = "send"
        ask.session = "T"
        ask.text = "rm -rf ~"
        ask.id = "r1"
        XCTAssertTrue(server.agentReply(ask).error?.contains("terminal") == true)

        server.perform(.end(session: "T"), from: nil)
        XCTAssertNil(server.session("T"))
        XCTAssertNil(record.process.processID, "ending the session ends its shell")
    }
}
