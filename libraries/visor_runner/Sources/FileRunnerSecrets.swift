import Foundation

/// The Runner's secrets in a file of its data folder (`runner-secrets.json`,
/// this user's alone), which the Runner's agent and its commands both read
/// and write, a lock file between them: the MCP servers' secret headers and
/// each Visor server's token for the proxy.
public final class FileRunnerSecrets: RunnerSecrets {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    private var lock: String { file.path + ".lock" }

    public func value(_ name: String) -> String? { locked { all()[name] } }

    public func set(_ name: String, _ value: String?) {
        locked {
            var values = all()
            values[name] = value.flatMap { $0.isEmpty ? nil : $0 }
            guard let data = try? JSONEncoder().encode(values) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Made by this user alone from the start, not opened up and then closed.
            if !FileManager.default.fileExists(atPath: file.path) {
                _ = FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try? data.write(to: file)
        }
    }

    private func all() -> [String: String] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// `body` with the lock held, against the other process.
    private func locked<Result>(_ body: () -> Result) -> Result {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lock, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        _ = flock(descriptor, LOCK_EX)
        defer { _ = flock(descriptor, LOCK_UN) }
        return body()
    }
}
