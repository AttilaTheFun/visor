// What gh_mcp's tests share (from AttilaTheFun/gh_mcp's GHMCPTests, at its
// #12): its server as agent-proxy holds it, with a fake GitHub and tokens;
// a call to it as a session makes one (CLIENT_ID, no key: agent-proxy has
// checked the sessions' token); git in a folder of the test's; a fake
// agent-token.

import Foundation
@testable import VisorGHMCP

func makeServer(transport: FakeTransport = FakeTransport(), remoteURL: (@Sendable (RepoName) -> String)? = nil,
                configuration: MCPServer.Configuration = MCPServer.Configuration(agent: "claude"),
                tokens: TokenCache = TokenCache(source: FixedToken()), log: CallLog = CallLog(path: nil)) -> MCPServer {
    let services = Services(
        transport: transport, tokens: tokens,
        remoteURL: remoteURL ?? { "https://github.com/\($0).git" }, scratch: NSTemporaryDirectory())
    return MCPServer(configuration: { configuration }, services: services, log: log)
}

func post(_ server: MCPServer, _ body: JSON, client: String? = nil) async -> (Int, JSON?) {
    var headers: [String: String] = [:]
    if let client { headers["CLIENT_ID"] = client }
    let response = await server.handle(MCPHTTPRequest(method: "POST", headers: headers, body: body.data()))
    return (response.status, try? JSON.parse(response.body))
}

func call(_ server: MCPServer, _ tool: String, _ arguments: JSON, client: String? = nil) async -> (text: String, isError: Bool) {
    let (_, json) = await post(server, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": arguments]],
                               client: client)
    let result = json?["result"]
    return (result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "", result?["isError"]?.boolValue ?? false)
}

@discardableResult
func sh(_ arguments: [String], in directory: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_AUTHOR_NAME"] = "T"; environment["GIT_AUTHOR_EMAIL"] = "t@example.com"
    environment["GIT_COMMITTER_NAME"] = "T"; environment["GIT_COMMITTER_EMAIL"] = "t@example.com"
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func temporaryFolder() -> String {
    let path = NSTemporaryDirectory() + "gh_mcp-test-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return (realPath(path) ?? path)
}

/// A fake agent-token in `folder`: each call's arguments kept in
/// `folder/calls`, a token printed that names the agent and how many
/// calls came before (`ghs_fake<agent><n>`); `broken` gets none.
func fakeAgentToken(in folder: String) throws -> String {
    let script = folder + "/agent-token"
    try """
        #!/bin/sh
        echo "$@" >> "\(folder)/calls"
        [ "$2" = broken ] && { echo "no app" >&2; exit 1; }
        echo "ghs_fake$2$(wc -l < "\(folder)/calls" | tr -d ' ')"
        """.write(toFile: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    return script
}
