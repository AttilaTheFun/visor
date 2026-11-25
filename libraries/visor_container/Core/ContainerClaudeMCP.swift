// The Sessions container's Claude told of agent-proxy's MCP pass-through
// (docs/containers.md, "MCP in the container"; 0.72.1): the servers a native
// session is passed on (gh, oss, …), each at
// `http://mcp.agent.internal/mcp/<name>`, the relay's dial-in to the
// pass-through. agent_protocol's wrapper starts its Claude with Visor's own
// server alone (`--mcp-config`, "visor"), and a job can't add to it; so these
// go where every Claude in the container reads them: its user MCP servers,
// `mcpServers` in its Claude folder's `.claude.json` (`<Sessions>/.claude`,
// CLAUDE_CONFIG_DIR), where Shireworks' `shireworks` entry was. Written at
// each boot, before the guest runs anything, so no Claude there writes the
// file meanwhile; and only when it changes.
//
// No entry holds a credential: each has a headersHelper,
// `visor-agent-host mcp-headers`, which asks the agent's own wrapper for its
// headers (a fresh token of the agent's, for MCP alone) each time Claude
// connects, and again when a server answers 401. An entry of Visor's is one
// with that helper: set by its name over whatever was there, and taken out
// once the pass-through no longer serves it. The rest of the file, and every
// other entry, is left as it was.

import Foundation

public struct ContainerClaudeMCP: Equatable, Sendable {
    /// The container's Claude folder (CLAUDE_CONFIG_DIR), at the same path
    /// on the Mac as in the guest.
    public var folder: String
    /// The pass-through's servers, each name's URL in the guest.
    public var servers: [String: String]

    public init(folder: String, servers: [String: String]) {
        self.folder = folder
        self.servers = servers
    }

    /// What each entry's headers come from, in the guest.
    public static let headersHelper = ContainerEngine.toolsInGuest + "/visor-agent-host mcp-headers"

    /// The file: Claude's own, in its folder.
    public var file: URL { URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(".claude.json") }

    /// `servers` written into the file (made, 0600, where there's none),
    /// when that changes it; said in the log. One that isn't a JSON object
    /// is left as it is.
    public func write(log: (String) -> Void) {
        let files = FileManager.default
        let exists = files.fileExists(atPath: file.path)
        var config: [String: Any] = [:]
        if exists {
            guard let data = try? Data(contentsOf: file), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                log("container: \(file.path) isn't a JSON object: the MCP pass-through's servers aren't put in it")
                return
            }
            config = object
        }
        guard let merged = Self.merged(config, servers: servers) else { return }
        let staged = file.deletingLastPathComponent().appendingPathComponent(".claude.json.visor-\(UUID().uuidString.prefix(8))")
        do {
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try files.createDirectory(atPath: folder, withIntermediateDirectories: true)
            // Made 0600 beside it, then moved over it: a reader sees the one
            // or the other, whole.
            guard files.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]),
                  rename(staged.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? files.removeItem(at: staged)
            log("container: the MCP pass-through's servers couldn't be put in \(file.path): \(error)")
            return
        }
        log("container: its Claude's MCP servers from agent-proxy's pass-through: "
            + (servers.isEmpty ? "none" : servers.keys.sorted().joined(separator: ", ")))
    }

    /// `config` (Claude's `.claude.json`, as read) with Visor's entries in
    /// its `mcpServers` as `servers` say: each set, by its name, and one of
    /// Visor's no longer served taken out. Nil when that changes nothing.
    static func merged(_ config: [String: Any], servers: [String: String]) -> [String: Any]? {
        let before = config["mcpServers"] as? [String: Any] ?? [:]
        var after = before
        for (name, entry) in before where isVisors(entry) && servers[name] == nil {
            after[name] = nil
        }
        for (name, url) in servers {
            after[name] = serverEntry(url)
        }
        guard !same(before, after) else { return nil }
        var config = config
        config["mcpServers"] = after
        return config
    }

    /// The entry for a server at `url`: no header of its own, only the
    /// helper that asks for them.
    static func serverEntry(_ url: String) -> [String: Any] {
        ["type": "http", "url": url, "headersHelper": headersHelper]
    }

    /// Whether `entry` is one of Visor's: its headersHelper is Visor's.
    static func isVisors(_ entry: Any) -> Bool {
        (entry as? [String: Any])?["headersHelper"] as? String == headersHelper
    }

    /// Whether two of `mcpServers` say the same, as JSON.
    private static func same(_ one: [String: Any], _ other: [String: Any]) -> Bool {
        let encode = { (value: [String: Any]) in try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        return encode(one) == encode(other)
    }
}
