import Foundation
import VisorContainerHost

/// The Runner's container servers (docs/co-tenancy.md): each a folder of
/// `folders` holding its `server.json`, and a launchd job of its own that
/// runs its container host's `serve` on that folder, from login on and
/// kept alive. So the Runner's quitting or updating leaves them, and their
/// sessions, running; and an update of a host loads its jobs again, which
/// ends and restarts each `serve` and leaves the containers and the servers
/// in them running.
public struct ContainerServerJobs: Sendable {
    /// Visor's own container host, in the Runner's bundle: the host of a
    /// container server that names no other.
    public var bundledHost: String
    /// `<Runner data>/container-servers`.
    public var folders: URL
    /// Where the jobs' plists go: ~/Library/LaunchAgents.
    public var agents: URL
    /// What the jobs' labels begin with (the Runner's bundle id), then
    /// `.container-server.<id>`.
    public var labelPrefix: String
    public var launchctl: Launchctl
    /// The folders a host named without a path is looked for in.
    public var path: [String]

    public init(bundledHost: String, folders: URL, labelPrefix: String,
                agents: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                launchctl: Launchctl = Launchctl(),
                path: [String] = Self.defaultPath) {
        self.bundledHost = bundledHost
        self.folders = folders
        self.labelPrefix = labelPrefix
        self.agents = agents
        self.launchctl = launchctl
        self.path = path
    }

    /// The PATH's folders, and those a login shell adds that an app
    /// started from the Finder doesn't have (Homebrew's, ~/.local/bin).
    public static var defaultPath: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let given = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return given + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin"]
    }

    /// What the Runner keeps of a container server, beside its
    /// `server.json`: `runner.json` in its folder.
    public struct Record: Codable, Equatable, Sendable {
        /// Its container host, with the arguments before the command (OS
        /// Server's adapter: `["oss", "container-host"]`); nil for Visor's
        /// own, wherever the Runner now is.
        public var host: [String]?
        /// Stopped from the Runner: its job not loaded, its container
        /// stopped, until it is started again.
        public var stopped = false

        public init(host: [String]? = nil, stopped: Bool = false) {
            self.host = host
            self.stopped = stopped
        }
    }

    public func folder(_ id: String) -> URL { folders.appendingPathComponent(id, isDirectory: true) }

    public func label(_ id: String) -> String { "\(labelPrefix).container-server.\(id)" }

    func plistFile(_ label: String) -> URL { agents.appendingPathComponent(label + ".plist") }

    func recordFile(_ id: String) -> URL { folder(id).appendingPathComponent("runner.json") }

    public func record(_ id: String) -> Record {
        (try? Data(contentsOf: recordFile(id))).flatMap { try? JSONDecoder().decode(Record.self, from: $0) } ?? Record()
    }

    func write(_ record: Record, _ id: String) throws {
        try JSONEncoder().encode(record).write(to: recordFile(id), options: .atomic)
    }

    /// The container servers there are: the folders with a `server.json`.
    public func servers() -> [ServerSpec] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folders, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { try? ServerSpec.read($0) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// What its host last found of a container server (`state.json`).
    public func state(_ id: String) -> ServerState? { ServerState.read(folder(id)) }

    /// A container server's host command, its program found: a path as it
    /// is, a name on `path`.
    public func host(_ id: String) throws -> [String] {
        let command = record(id).host ?? [bundledHost]
        guard let program = command.first else { throw ContainerHostError("\(id)'s container host is empty") }
        if program.contains("/") { return command }
        guard let found = path.map({ $0 + "/" + program }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ContainerHostError("No \(program) on the PATH, for \(id)'s container host")
        }
        return [found] + command.dropFirst()
    }

    /// A program's build as the file system has it (its size and when it
    /// was written): a new build of the host changes its jobs, so they are
    /// loaded again and run it.
    static func build(of program: String) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: program) else { return "" }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let written = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int64(written))"
    }

    /// A container server's job as it should be now.
    public func job(_ id: String) throws -> LaunchJob {
        let host = try host(id)
        return LaunchJob(label: label(id), programArguments: host + ["serve", folder(id).path],
                         environmentVariables: ["VISOR_CONTAINER_HOST_BUILD": Self.build(of: host[0])],
                         log: folder(id).appendingPathComponent("host.log").path)
    }

    /// Every container server's job loaded as it should be, but for those
    /// stopped from the Runner; and a job of the Runner's whose server is
    /// gone unloaded and its plist removed. What went wrong, by server.
    @discardableResult
    public func refresh() -> [String: String] {
        var problems: [String: String] = [:]
        let ids = Set(servers().map(\.id))
        for id in ids.sorted() where !record(id).stopped {
            if let problem = load(id) { problems[id] = problem }
        }
        let prefix = labelPrefix + ".container-server."
        let plists = (try? FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)) ?? []
        for file in plists where file.pathExtension == "plist" && file.lastPathComponent.hasPrefix(prefix) {
            let id = String(file.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))
            if !ids.contains(id), let problem = unload(id) { problems[id] = problem }
        }
        return problems
    }

    /// The server's job loaded as it should be now: left as it is when it
    /// already is; loaded again when it has changed (a new host). Nil, or
    /// what went wrong.
    func load(_ id: String) -> String? {
        let job: LaunchJob
        do { job = try self.job(id) } catch { return "\(error)" }
        let file = plistFile(job.label)
        let loaded = launchctl.loaded(job.label)
        if loaded, LaunchJob.read(file) == job { return nil }
        if loaded, let problem = launchctl.unload(job.label) { return problem }
        do {
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try job.plist().write(to: file, options: .atomic)
        } catch {
            return "\(error)"
        }
        return launchctl.load(file)
    }

    /// The server's job unloaded and its plist gone: its `serve` ended, its
    /// container and server left running.
    func unload(_ id: String) -> String? {
        let label = label(id)
        if launchctl.loaded(label), let problem = launchctl.unload(label) { return problem }
        try? FileManager.default.removeItem(at: plistFile(label))
        return nil
    }

    /// A new container server: its folder (this user's alone), its
    /// `server.json` and the Runner's record written, and its job loaded.
    /// Nil, or what went wrong in loading it.
    public func make(_ spec: ServerSpec, host: [String]? = nil) throws -> String? {
        let folder = folder(spec.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(spec).write(to: folder.appendingPathComponent("server.json"), options: .atomic)
        try write(Record(host: host), spec.id)
        return load(spec.id)
    }

    /// A stopped server started again: its job loaded, which starts its
    /// container. Nil, or what went wrong.
    public func start(_ id: String) -> String? {
        var record = record(id)
        record.stopped = false
        do { try write(record, id) } catch { return "\(error)" }
        return load(id)
    }

    /// The server stopped until it is started again: its job unloaded, then
    /// its container stopped by its host (its disks kept). Nil, or what
    /// went wrong.
    public func stop(_ id: String) -> String? {
        var record = record(id)
        record.stopped = true
        do { try write(record, id) } catch { return "\(error)" }
        if let problem = unload(id) { return problem }
        return run(id, "stop").error
    }

    /// The server gone: its job unloaded, its container, disks and secrets
    /// removed by its host, and its folder. Nil, or what went wrong (the
    /// folder is kept then, to try again).
    public func remove(_ id: String) -> String? {
        if let problem = unload(id) { return problem }
        if let problem = run(id, "remove", "--data").error { return problem }
        do { try FileManager.default.removeItem(at: folder(id)) } catch { return "\(error)" }
        return nil
    }

    /// The agents' sign-ins and the MCP servers' secret headers given to
    /// the server's host (its `credentials`: `{"claudeToken"?,
    /// "openrouterKey"?, "codexAuth"?, "mcpSecrets"?}`, null to take one
    /// away). The names it kept, or what went wrong.
    public func credentials(_ id: String, _ given: Data) -> Result<[String], ContainerHostError> {
        let answer = run(id, "credentials", input: given)
        if let error = answer.error { return .failure(ContainerHostError(error)) }
        return .success(answer.json["kept"] as? [String] ?? [])
    }

    /// A host command's answer for the server: its JSON, and its error when
    /// it failed.
    func run(_ id: String, _ command: String, _ more: String..., input: Data? = nil) -> (json: [String: Any], error: String?) {
        let host: [String]
        do { host = try self.host(id) } catch { return ([:], "\(error)") }
        guard let ran = Tool(host[0]).run(Array(host.dropFirst()) + [command, folder(id).path] + more, input: input) else {
            return ([:], "\(host[0]) couldn't be run")
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(ran.output.utf8))) as? [String: Any] ?? [:]
        if ran.status == 0 { return (json, nil) }
        return (json, json["error"] as? String ?? ran.said)
    }
}
