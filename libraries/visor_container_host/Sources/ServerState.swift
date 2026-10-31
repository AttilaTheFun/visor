import Foundation

/// What a container host last found of its container server
/// (docs/co-tenancy.md): `state.json` in its folder, written by `serve`, and
/// what `status` answers.
public struct ServerState: Codable, Equatable, Sendable {
    /// starting, ready, stopped or failed.
    public var state: String
    public var container: String?
    public var server: Server?
    /// Where clients reach the server: the host's port.
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

    public static func read(_ folder: URL) -> ServerState? {
        (try? Data(contentsOf: file(folder))).flatMap { try? JSONDecoder().decode(ServerState.self, from: $0) }
    }

    public func write(_ folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(self) { try? data.write(to: Self.file(folder), options: .atomic) }
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
