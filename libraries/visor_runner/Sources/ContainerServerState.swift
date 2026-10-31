import Foundation

/// What the Runner last found of a container server (docs/co-tenancy.md):
/// `state.json` in its folder, which Settings shows.
public struct ContainerServerState: Codable, Equatable, Sendable {
    /// starting, ready, stopped or failed.
    public var state: String
    public var container: String?
    public var server: Server?
    /// Where clients reach the server: the port published on this computer.
    public var address: String?
    /// The server's connection code, leading with `address`.
    public var code: String?
    public var network: Network?
    public var error: String?

    public struct Server: Codable, Equatable, Sendable {
        public var version: String?
        public var answering: Bool
    }

    public struct Network: Codable, Equatable, Sendable {
        public var ok: Bool
        public var detail: String
    }

    public init(state: String) {
        self.state = state
    }

    static func file(_ folder: URL) -> URL { folder.appendingPathComponent("state.json") }

    public static func read(_ folder: URL) -> ContainerServerState? {
        (try? Data(contentsOf: file(folder))).flatMap { try? JSONDecoder().decode(ContainerServerState.self, from: $0) }
    }

    public func write(_ folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(self).write(to: Self.file(folder), options: .atomic)
    }
}
