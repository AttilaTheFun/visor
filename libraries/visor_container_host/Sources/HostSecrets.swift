import Foundation

/// Where a container host keeps a container server's secrets: its server's
/// password, the agents' sign-ins and the MCP servers' secret headers,
/// each by name. A debug build keeps them in a file of the server's folder
/// that only this user reads (FileHostSecrets); a notarized one, in the
/// keychain.
public protocol HostSecrets: Sendable {
    func value(_ name: String) -> String?
    /// Keeps a value, or forgets it (nil).
    func set(_ name: String, _ value: String?) throws
}

/// Secrets in `secrets.json` in a container server's folder, mode 600.
public struct FileHostSecrets: HostSecrets {
    public let file: URL

    public init(folder: URL) {
        file = folder.appendingPathComponent("secrets.json")
    }

    private func all() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }

    public func value(_ name: String) -> String? { all()[name] }

    public func set(_ name: String, _ value: String?) throws {
        var values = all()
        values[name] = value
        let data = try JSONEncoder().encode(values)
        // Made by this user alone from the start, not opened up and then closed.
        if !FileManager.default.fileExists(atPath: file.path) {
            _ = FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
