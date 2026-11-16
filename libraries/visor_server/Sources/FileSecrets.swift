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
        guard case .found(let value) = lookup(key) else { return nil }
        return value
    }

    /// Absent when the file, or its key, isn't there; unreadable when the
    /// file is there but can't be read or isn't JSON.
    public func lookup(_ key: String) -> SecretLookup {
        lock.withLock { _ -> SecretLookup in
            switch read() {
            case .success(let values): return values[key].map(SecretLookup.found) ?? .absent
            case .failure(let why): return .unreadable(why.message)
            }
        }
    }

    /// A secrets file that can't be read is never written over: every
    /// other secret in it would go.
    public func set(_ key: String, _ value: String?) {
        lock.withLock { _ in
            guard case .success(var values) = read() else { return }
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

    /// Why the file couldn't be read.
    private struct Unreadable: Error {
        let message: String
    }

    /// The file's secrets: none where there is no file (or it is empty).
    private func read() -> Result<[String: String], Unreadable> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success([:]) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { return .failure(Unreadable(message: "\(url.path) can't be read: \(error)")) }
        if data.isEmpty { return .success([:]) }
        guard let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return .failure(Unreadable(message: "\(url.path) isn't a JSON object of secrets"))
        }
        return .success(values)
    }
}
