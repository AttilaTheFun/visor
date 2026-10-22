// A container session's agent log, mirrored onto this computer: read from
// the container's home over oss's API as it grows, from where the copy
// here ends, and appended to the copy, which the session's indexer follows
// as it would the agent's own log on this computer.

import ClaudeTranscript
import Foundation
import VisorProtocol

@MainActor
final class ContainerLogMirror {
    /// The copy here.
    let url: URL
    let format: AgentLog.Format
    private var copying: Task<Void, Never>?

    /// Where a session's copies are kept: beside the server's store.
    static var folder: URL { VisorServer.storeURL.deletingLastPathComponent().appendingPathComponent("containers", isDirectory: true) }

    private init(url: URL, format: AgentLog.Format) {
        self.url = url
        self.format = format
    }

    /// The copy, once it has something in it: where the indexer reads.
    var located: (url: URL, format: AgentLog.Format)? {
        FileManager.default.fileExists(atPath: url.path) ? (url, format) : nil
    }

    /// Mirrors the log of the agent's session `id` (Claude's session,
    /// Codex's thread) in `placement`'s container, the agent working in
    /// `cwd` there; nil for an agent whose log is not found there.
    static func start(agent: AgentKind, id: String, cwd: String, session: String, placement: ContainerPlacement) -> ContainerLogMirror? {
        let format: AgentLog.Format
        switch agent {
        case .claude: format = .claude
        case .codex: format = .codex
        case .openrouter: return nil
        }
        let folder = Self.folder.appendingPathComponent(session, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mirror = ContainerLogMirror(url: folder.appendingPathComponent(id + ".jsonl", isDirectory: false), format: format)
        let url = mirror.url, server = placement.server, container = placement.session
        mirror.copying = Task.detached {
            // oss's token as kept when each ask is made.
            let client: @Sendable () async -> OSSClient = { await OSSClient(server: server, token: MainActor.run { ContainerPlacement.token() }) }
            guard let path = await Self.remotePath(agent: agent, id: id, cwd: cwd, client: client, session: container) else { return }
            await Self.copy(path, of: container, client: client, to: url)
        }
        return mirror
    }

    func stop() {
        copying?.cancel()
        copying = nil
    }

    /// The log's path in the container's home: Claude's under its project
    /// folder for `cwd` (named the same way there as here); Codex's
    /// rollout, found by its thread's id once Codex has written it.
    nonisolated static func remotePath(agent: AgentKind, id: String, cwd: String, client: @Sendable () async -> OSSClient, session: String) async -> String? {
        switch agent {
        case .claude:
            return ".claude/projects/\(ClaudeSessionFiles.projectDirectoryName(for: cwd))/\(id).jsonl"
        case .codex:
            for _ in 0..<120 where !Task.isCancelled {
                let found = (try? await client().run(session, ["sh", "-c", "find /root/.codex/sessions -name '*\(id).jsonl' 2>/dev/null | head -1"])) ?? ""
                let path = found.trimmingCharacters(in: .whitespacesAndNewlines)
                if path.hasPrefix("/root/") { return String(path.dropFirst("/root/".count)) }
                try? await Task.sleep(for: .seconds(2))
            }
            return nil
        case .openrouter:
            return nil
        }
    }

    /// Copies the file on as it grows: what is past the copy's end,
    /// appended; a file that shrank (written anew) copied again from its
    /// start. oss out of reach is asked again, less often the longer it is.
    nonisolated static func copy(_ path: String, of session: String, client: @Sendable () async -> OSSClient, to url: URL) async {
        var offset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var failures = 0
        while !Task.isCancelled {
            do {
                guard let part = try await client().readFile(session, path: path, from: offset, wait: OSSClient.longestWait) else {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                failures = 0
                if part.size < offset {
                    try? FileManager.default.removeItem(at: url)
                    offset = 0
                    continue
                }
                // An oss that reads no offsets gives the whole file: what
                // is past the copy's end is the new part.
                let new = part.whole ? part.data.dropFirst(offset) : part.data[...]
                if !new.isEmpty {
                    append(Data(new), to: url)
                    offset += new.count
                }
                if part.whole { try? await Task.sleep(for: .seconds(1)) }
            } catch {
                failures += 1
                try? await Task.sleep(for: .seconds(min(30, 2 * failures)))
            }
        }
    }

    nonisolated private static func append(_ data: Data, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
