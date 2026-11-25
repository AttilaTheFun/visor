// agent-proxy's MCP pass-through's servers put in the Sessions container's
// Claude's own file (ContainerClaudeMCP; docs/containers.md, "MCP in the
// container"), at each boot before anything runs in it: each at its URL
// with Visor's headersHelper and no credential, Visor's entries no longer
// served taken out, the rest of the file and every other entry left as they
// were, the file written only when it changes, and one that isn't JSON left
// alone.

import Foundation
import Testing
import VisorContainerCore

extension EngineTests {
    @Test func thePassThroughsServersArePutInItsClaudesFileAtItsBoot() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let sessions = rig.root.appendingPathComponent("Sessions", isDirectory: true)
        let folder = sessions.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(".claude.json")
        let helper = "/opt/visor/bin/visor-agent-host mcp-headers"
        #expect(ContainerClaudeMCP.headersHelper == helper)
        let before: [String: Any] = [
            "numStartups": 7, "hasCompletedOnboarding": true, "projects": ["/Volumes/Sessions/Claude/x": ["allowedTools": [String]()]],
            "mcpServers": ["mine": ["type": "stdio", "command": "mine"],
                           "retired": ["type": "http", "url": "http://mcp.agent.internal/mcp/retired", "headersHelper": helper]],
        ]
        try JSONSerialization.data(withJSONObject: before).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let servers = ["gh": "http://mcp.agent.internal/mcp/gh", "oss": "http://mcp.agent.internal/mcp/oss"]
        rig.change { $0.claudeMCP = ContainerClaudeMCP(folder: folder.path, servers: servers) }
        let engine = rig.engine(sessions: sessions.path)
        let status = await engine.start()
        #expect(status.state == .running, "\(status.errors)")
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let mcp = try #require(after["mcpServers"] as? [String: Any])
        #expect(Set(mcp.keys) == ["mine", "gh", "oss"], "Visor's served, Visor's no longer served taken out, the person's own kept")
        for (name, url) in servers {
            #expect((mcp[name] as? [String: String]) == ["type": "http", "url": url, "headersHelper": helper], "\(name)")
        }
        #expect((mcp["mine"] as? [String: String]) == ["type": "stdio", "command": "mine"])
        #expect(after["numStartups"] as? Int == 7 && after["hasCompletedOnboarding"] as? Bool == true && after["projects"] != nil,
                "the rest of Claude's file as it was")
        // No credential: the headers are the helper's to ask for, each time.
        let text = try String(contentsOf: file, encoding: .utf8)
        for word in ["X-Visor-Proxy", "Bearer", "token", "\"headers\""] {
            #expect(!text.contains(word), "\(word)")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        _ = await engine.stop()
    }

    @Test func itsClaudesFileIsWrittenOnlyWhenItsServersChangeIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-mcp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = ContainerClaudeMCP(folder: folder.path, servers: ["gh": "http://mcp.agent.internal/mcp/gh"])
        let none = ContainerClaudeMCP(folder: folder.path, servers: [:])
        var said: [String] = []
        none.write { said.append($0) }
        #expect(!FileManager.default.fileExists(atPath: one.file.path) && said.isEmpty, "none to put, and no file: none made")
        one.write { said.append($0) }
        let made = try Data(contentsOf: one.file)
        #expect(said.last?.hasSuffix("pass-through: gh") == true, "\(said)")
        let mode = try FileManager.default.attributesOfItem(atPath: one.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600, "made as Claude makes it, its own alone")
        said = []
        one.write { said.append($0) }
        let again = try Data(contentsOf: one.file)
        #expect(said.isEmpty && again == made, "the same again: left as it is")
        none.write { said.append($0) }
        let emptied = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: one.file)) as? [String: Any])
        #expect((emptied["mcpServers"] as? [String: Any])?.isEmpty == true, "Visor's taken out once none is served")
        try Data("{not json".utf8).write(to: one.file)
        said = []
        one.write { said.append($0) }
        #expect(try String(contentsOf: one.file, encoding: .utf8) == "{not json", "a file that isn't JSON is left alone")
        #expect(said.first?.contains("isn't a JSON object") == true, "\(said)")
    }
}
