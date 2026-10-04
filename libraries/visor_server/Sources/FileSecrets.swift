import Foundation
import Synchronization

/// Secrets in a JSON file that only its owner may read or write (made with
/// those permissions where the system has them): a command-line server's,
/// where there is no keychain to ask.
public final class FileSecrets: SecretStore {
    private let url: URL
    private let lock = Mutex(())

    public init(url: URL) {
        self.url = url
    }

    public func get(_ key: String) -> String? {
        lock.withLock { _ in read()[key] }
    }

    public func set(_ key: String, _ value: String?) {
        lock.withLock { _ in
            var values = read()
            values[key] = value.flatMap { $0.isEmpty ? nil : $0 }
            guard let data = try? JSONEncoder().encode(values) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try? data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func read() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
