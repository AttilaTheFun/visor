// `/login` in a Claude session: `claude auth login` run with no terminal,
// its page found in what it prints (through the terminal's hyperlink
// markup), and the code the user sends written to it.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class SignInTests: ServerTestCase {
    /// A stand-in for `claude auth login`: the page, then the prompt; a
    /// code of the right shape signs in.
    private func fakeClaude() throws -> String {
        let path = NSTemporaryDirectory() + "fake-claude-" + UUID().uuidString
        let script = #"""
            #!/bin/sh
            printf 'Opening browser to sign in\342\200\246\n'
            printf 'If the browser did not open, visit: \033]8;;https://claude.ai/oauth/authorize?code=true&state=s1\033\\https://claude.ai/oauth/authorize?code=true&state=s1\033]8;;\033\\\n'
            printf 'Paste code here if prompted > '
            read line
            if [ "$line" = "abc#s1" ]; then echo 'Login successful.'; exit 0; fi
            echo 'Login failed: Invalid code' >&2; exit 1
            """#
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testTheWordsThatStartIt() {
        XCTAssertEqual(VisorServer.signInArguments("/login"), [])
        XCTAssertEqual(VisorServer.signInArguments(" /login --console "), ["--console"])
        XCTAssertNil(VisorServer.signInArguments("/loginx"))
        XCTAssertNil(VisorServer.signInArguments("please /login"))
    }

    func testThePageIsFoundAndTheCodeSignsIn() async throws {
        let signIn = try ClaudeSignIn(claude: try fakeClaude(), arguments: [], environment: ProcessInfo.processInfo.environment)
        var page: String?
        var result: (Bool, String)?
        signIn.onURL = { page = $0 }
        signIn.onEnd = { result = ($0, $1) }
        for _ in 0..<100 where page == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(page, "https://claude.ai/oauth/authorize?code=true&state=s1")
        XCTAssertEqual(signIn.url, page)
        signIn.submit(" abc#s1 \n")
        for _ in 0..<100 where result == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(result?.0, true)
        XCTAssertEqual(result?.1, "Login successful.")
    }

    func testAWrongCodeSaysWhy() async throws {
        let signIn = try ClaudeSignIn(claude: try fakeClaude(), arguments: [], environment: ProcessInfo.processInfo.environment)
        var result: (Bool, String)?
        signIn.onEnd = { result = ($0, $1) }
        for _ in 0..<100 where signIn.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        signIn.submit("nope")
        for _ in 0..<100 where result == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(result?.0, false)
        XCTAssertEqual(result?.1, "Login failed: Invalid code")
    }

    func testTerminalMarkupIsTakenOff() {
        XCTAssertEqual(ClaudeSignIn.plain("\u{1B}[1mbold\u{1B}[0m \u{1B}]8;;https://x\u{07}link\u{1B}]8;;\u{07}"), "bold link")
        XCTAssertNil(ClaudeSignIn.url(in: "visit: https://claude.ai/oauth/auth"), "not yet the whole address")
    }
}
