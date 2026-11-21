// The audit log, as gh_mcp wrote it: a line a tool call, `<time>
// <session>@visor <tool> <repository> <outcome>`, the session its
// CLIENT_ID; never a token, a key or a body.

import Foundation
import Testing
@testable import VisorGHMCP

@Test func eachCallIsALineOfTheAuditLog() async throws {
    let folder = temporaryFolder()
    let path = folder + "/logs/Visor-gh.log"
    let transport = FakeTransport([
        "GET /repos/AttilaTheFun/oss/pulls": (200, []),
        "GET /repos/AttilaTheFun/oss/pulls/9": (401, ["message": "Bad credentials: ghs_abcdefghijklmnopqrst"]),
    ])
    let server = makeServer(transport: transport, log: CallLog(path: path))
    _ = await call(server, "pr_list", ["repo": "AttilaTheFun/oss"], client: "1f2e3d4c-session")
    _ = await call(server, "pr_list", ["repo": "someone/else"], client: "1f2e3d4c-session")
    _ = await call(server, "pr_view", ["repo": "AttilaTheFun/oss", "number": 9, "body": "a body"], client: "other")
    _ = await call(server, "pr_view", ["repo": "AttilaTheFun/oss", "number": 9])
    _ = await post(server, ["jsonrpc": "2.0", "id": 9, "method": "tools/list"], client: "lister")
    let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(lines.count == 4, "a line a tool call, none for a listing: \(lines)")
    let fields = lines.map { $0.split(separator: " ", maxSplits: 4).map(String.init) }
    #expect(fields.allSatisfy { $0.count == 5 && ISO8601DateFormatter().date(from: $0[0]) != nil }, "\(lines)")
    #expect(fields.map { $0[1] } == ["1f2e3d4c-session@visor", "1f2e3d4c-session@visor", "other@visor", "-@visor"])
    #expect(fields.map { $0[2] } == ["pr_list", "pr_list", "pr_view", "pr_view"])
    #expect(fields.map { $0[3] } == ["AttilaTheFun/oss", "someone/else", "AttilaTheFun/oss", "AttilaTheFun/oss"])
    #expect(fields[0][4] == "ok")
    #expect(fields[1][4].hasPrefix("refused: someone/else is not among the repositories gh_mcp allows"))
    #expect(fields[2][4].hasPrefix("invalid: pr_view takes no argument body"))
    #expect(fields[3][4].hasPrefix("failed: GitHub answered 401"))
    let text = lines.joined(separator: "\n")
    #expect(!text.contains("ghs_abc") && !text.contains("ghs_testtoken") && !text.contains("a body"), "no token or body: \(text)")
    #expect(text.contains("ghs_[redacted]"))
}

@Test func theLogSaysItBegan() throws {
    let path = temporaryFolder() + "/Visor-gh.log"
    CallLog(path: path).note("0.1.0 in agent-proxy at /mcp/gh; token ghs_abcdefghijklmnop")
    let line = try String(contentsOfFile: path, encoding: .utf8)
    #expect(line.contains(" gh_mcp 0.1.0 in agent-proxy at /mcp/gh") && line.contains("ghs_[redacted]") && !line.contains("ghs_abc"))
    #expect(line.hasSuffix("\n"))
}
