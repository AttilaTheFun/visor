import Foundation
import Synchronization

/// The call log, gh_mcp's audit: a line a tool call, with the time,
/// `<client id>@<application>`, the tool, the repository and the outcome.
/// Never a token, a key or a body. In Visor, the session's id is the client
/// id (CLIENT_ID, behind the sessions' token at agent-proxy), and the file
/// is in the server's logs folder unless the settings name another
/// (`agentProxy.gh.auditLog`).
public final class CallLog: Sendable {
    public let path: String?
    /// Held while a line is written, so lines never interleave.
    private let writing = Mutex(())

    /// `path` nil: lines go to standard error (a test's, or with no file).
    public init(path: String?) {
        self.path = path
        if let path {
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
    }

    public static func line(time: Date, caller: String, tool: String, repo: String, outcome: String) -> String {
        let fields = [time.formatted(.iso8601), caller, tool, repo].map { field in
            String(field.map { $0.isWhitespace ? "_" : $0 })
        }
        return (fields + [Redact.line(outcome, limit: 300)]).joined(separator: " ")
    }

    public func record(caller: String, tool: String, repo: String, outcome: String, time: Date = Date()) {
        write(Self.line(time: time, caller: caller, tool: tool, repo: repo, outcome: outcome))
    }

    /// A line about the server itself (it started, its settings).
    public func note(_ message: String, time: Date = Date()) {
        write("\(time.formatted(.iso8601)) gh_mcp \(Redact.line(message, limit: 500))")
    }

    private func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        writing.withLock { _ in
            guard let path else {
                FileHandle.standardError.write(data)
                return
            }
            if !FileManager.default.fileExists(atPath: path) {
                _ = FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
