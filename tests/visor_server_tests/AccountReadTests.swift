// An agent's account read when it is about to be shown, not only heard
// from a session's turns: OpenAI resets Codex's limits now and then while
// no session runs. A stand-in `codex` answers the app-server's reads.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class AccountReadTests: ServerTestCase {
    private var folder: URL!
    private var path: String?
    private var server: VisorServer!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-account-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Codex's app-server, as far as the reads go: each run noted.
        let codex = folder.appendingPathComponent("codex")
        try Data("""
        #!/bin/sh
        echo run >> "\(folder.path)/runs"
        while IFS= read -r line; do
          case "$line" in
            *'"id":2'*) echo '{"id":2,"result":{"account":{"type":"chatgpt","email":"a@b.c","planType":"pro"}}}' ;;
            *'"id":3'*) echo '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1800000000},"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":"10.5"}}}}' ;;
          esac
        done

        """.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        path = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "\(folder.path):/usr/bin:/bin", 1)
        // Never the real archive or keychain.
        VisorServer.storeRoot = folder
        VisorServer.secrets = MemorySecrets()
        VisorServer.socketPathOverride = "/tmp/visor-account-\(getpid()).sock"
        server = VisorServer(port: 7996)
    }

    override func tearDown() async throws {
        server.stop()
        VisorServer.socketPathOverride = nil
        if let path { setenv("PATH", path, 1) } else { unsetenv("PATH") }
        try? FileManager.default.removeItem(at: folder)
    }

    private var runs: Int {
        ((try? String(contentsOf: folder.appendingPathComponent("runs"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    func testCodexSaysHowItsAccountStandsNow() async throws {
        let read = await CodexHarness().readAccount()
        let account = try XCTUnwrap(read)
        XCTAssertEqual(account.plan, "ChatGPT Pro")
        XCTAssertTrue(account.subscription)
        XCTAssertEqual(account.limits, [UsageLimit(name: "Weekly", used: 0, resets: 1_800_000_000),
                                        UsageLimit(name: "Credits", left: 10.5, unit: .credits)])
    }

    /// A week's window that was reset: what a turn left days ago gives
    /// way to what Codex says now, and a second look moments later reads
    /// nothing again.
    func testTheServerKeepsWhatCodexSaysNow() async throws {
        server.knownAccounts = [.codex: AgentAccount(plan: "ChatGPT Pro", subscription: true,
                                                     limits: [UsageLimit(name: "Weekly", used: 0.94, resets: 1_700_000_000)], updated: 1)]
        await server.refreshAccount(of: .codex)
        let account = try XCTUnwrap(server.account(for: .codex))
        XCTAssertEqual(account.limits.first, UsageLimit(name: "Weekly", used: 0, resets: 1_800_000_000))
        XCTAssertGreaterThan(account.updated, Date().timeIntervalSince1970 - 60)
        XCTAssertEqual(VisorServer.keptAccounts()[.codex], account, "kept on disk")

        await server.refreshAccount(of: .codex)
        XCTAssertEqual(runs, 1, "a read a moment ago is fresh enough")
        // Claude's is only heard from its turns: nothing to ask.
        await server.refreshAccount(of: .claude)
        XCTAssertNil(server.account(for: .claude))
    }
}
