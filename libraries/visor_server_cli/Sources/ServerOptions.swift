import Foundation

/// How the server is run: what `run` and `start` take after the command,
/// and, below them, what its environment says (docs/server-proxy.md: a
/// server is told where it is by its environment or its arguments):
///
///   VISOR_PORT              --port
///   VISOR_LISTEN            --listen all|loopback (the LAN and a VPN, or
///                           this computer alone)
///   VISOR_PASSWORD_FILE     --password-file (the password, from a file)
///   VISOR_FRONT             --front (where clients reach it, comma-separated)
///   VISOR_PROXY             --proxy (where its pushes and MCP servers go)
///   VISOR_PROXY_TOKEN_FILE  --proxy-token-file (its token for the proxy)
///   VISOR_MCP               --mcp (the proxy's MCP servers to pass on)
///   VISOR_SESSIONS_DIR      --sessions-dir (a folder for each session there)
///   VISOR_SOURCES_DIR       --sources-dir (where moved sessions' repositories go)
struct ServerOptions: Sendable {
    var port: UInt16?
    /// The file it logs to; the terminal when nil.
    var log: String?
    /// A process to wait for before listening: the server this one
    /// replaces.
    var after: Int32?
    /// The sessions to carry on (`--resume-sessions`, read by the server).
    var resume: String?
    /// Settings to keep before it runs: `--auth`, `--lan`, `--vpn`,
    /// `--ssh`, `--address`, `--standalone`, `--front`, `--keep-messages`,
    /// as the commands of those names keep them (the flag without its
    /// dashes, and its value).
    var settings: [(String, String)] = []
    /// The password to set before it runs.
    var password: String?
    /// The proxy given at start, its token, and the MCP servers of it to
    /// pass on (VisorServer.useProxy).
    var proxy: String?
    var proxyToken: String?
    var mcp: [String] = []
    /// A folder for each session under `sessionsDir`, and the repositories
    /// under `sourcesDir` (SessionFolders).
    var sessionsDir: String?
    var sourcesDir: String?
    /// The files the password and the proxy's token were read from: passed
    /// on to a run started from this one in place of the values, which go
    /// on no command line.
    private var passwordFile: String?
    private var proxyTokenFile: String?

    /// None given.
    init() {}

    /// Reads the environment's, then the arguments', which win; what it does
    /// not know is returned as the problem.
    init(_ arguments: [String], environment: [String: String] = [:]) throws(CommandLineError) {
        try take(environment)
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard let value = rest.popFirst() else { throw .usage("\(flag) needs a value") }
            switch flag {
            case "--port":
                guard let port = UInt16(value) else { throw .usage("--port takes a number") }
                self.port = port
            case "--log": log = value
            case "--after":
                guard let pid = Int32(value) else { throw .usage("--after takes a process id") }
                after = pid
            case "--resume-sessions": resume = value
            case "--password": password = value
            case "--password-file": password = try Self.read(value, for: flag); passwordFile = value
            case "--listen": settings += try Self.listening(value)
            case "--proxy": proxy = value
            case "--proxy-token-file": proxyToken = try Self.read(value, for: flag); proxyTokenFile = value
            case "--mcp": mcp = Self.names(value)
            case "--sessions-dir": sessionsDir = try Self.folder(value, for: flag)
            case "--sources-dir": sourcesDir = try Self.folder(value, for: flag)
            case "--auth", "--lan", "--vpn", "--ssh", "--address", "--standalone", "--front", "--keep-messages":
                settings.append((String(flag.dropFirst(2)), value))
            default: throw .usage("unknown option \(flag)")
            }
        }
    }

    /// What the environment says, as the arguments would.
    private mutating func take(_ environment: [String: String]) throws(CommandLineError) {
        func given(_ name: String) -> String? {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return value
        }
        if let value = given("VISOR_PORT") {
            guard let port = UInt16(value) else { throw .usage("VISOR_PORT takes a number") }
            self.port = port
        }
        if let value = given("VISOR_LISTEN") { settings += try Self.listening(value) }
        if let value = given("VISOR_PASSWORD_FILE") { password = try Self.read(value, for: "VISOR_PASSWORD_FILE"); passwordFile = value }
        if let value = given("VISOR_FRONT") { settings.append(("front", value)) }
        if let value = given("VISOR_PROXY") { proxy = value }
        if let value = given("VISOR_PROXY_TOKEN_FILE") { proxyToken = try Self.read(value, for: "VISOR_PROXY_TOKEN_FILE"); proxyTokenFile = value }
        if let value = given("VISOR_MCP") { mcp = Self.names(value) }
        if let value = given("VISOR_SESSIONS_DIR") { sessionsDir = try Self.folder(value, for: "VISOR_SESSIONS_DIR") }
        if let value = given("VISOR_SOURCES_DIR") { sourcesDir = try Self.folder(value, for: "VISOR_SOURCES_DIR") }
    }

    /// A folder's full path.
    static func folder(_ value: String, for name: String) throws(CommandLineError) -> String {
        guard value.hasPrefix("/") else { throw .usage("\(name) takes a folder's full path") }
        return value
    }

    /// `all` (or an address that is every interface's): the LAN and a VPN
    /// reach the port; `loopback` (or its address): this computer alone.
    static func listening(_ value: String) throws(CommandLineError) -> [(String, String)] {
        switch value.lowercased() {
        case "all", "0.0.0.0", "::", "*": return [("lan", "on"), ("vpn", "on")]
        case "loopback", "localhost", "127.0.0.1", "::1": return [("lan", "off"), ("vpn", "off")]
        default: throw .usage("listen on all, or loopback")
        }
    }

    /// A secret's file, its one line: never the value itself in the
    /// environment or on a command line.
    static func read(_ path: String, for name: String) throws(CommandLineError) -> String {
        guard let data = FileManager.default.contents(atPath: path),
              case let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { throw .usage("\(name): nothing to read at \(path)") }
        return value
    }

    /// `shireworks, gh` as names.
    static func names(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// As arguments again, for a run started from this one.
    var arguments: [String] {
        var out: [String] = []
        if let port { out += ["--port", String(port)] }
        if let log { out += ["--log", log] }
        if let after { out += ["--after", String(after)] }
        if let resume { out += ["--resume-sessions", resume] }
        if let passwordFile { out += ["--password-file", passwordFile] } else if let password { out += ["--password", password] }
        for (name, value) in settings { out += ["--" + name, value] }
        if let proxy { out += ["--proxy", proxy] }
        if let proxyTokenFile { out += ["--proxy-token-file", proxyTokenFile] }
        if !mcp.isEmpty { out += ["--mcp", mcp.joined(separator: ",")] }
        if let sessionsDir { out += ["--sessions-dir", sessionsDir] }
        if let sourcesDir { out += ["--sources-dir", sourcesDir] }
        return out
    }
}
