#if canImport(Foundation)
import Foundation
#endif

/// Whose window a terminal session is drawn for. A shell's terminal is
/// one fixed size on the computer, so it belongs to exactly one client at
/// a time: the mode carries that client and its window. A chat session is
/// always `chat`, drawn by each client for its own screen, and so is a
/// terminal session no window has taken yet.
public enum SessionMode: Hashable, Sendable {
    /// No window has the terminal (and, for a chat, none needs it).
    case chat
    /// A terminal session's shell, on a terminal of `cols` × `rows`,
    /// drawn for the client that took it.
    case tui(controller: String, cols: Int, rows: Int)

    public var isTUI: Bool { if case .tui = self { true } else { false } }

    /// The client the terminal is drawn for, if any.
    public var controller: String? {
        if case .tui(let controller, _, _) = self { controller } else { nil }
    }

    public var terminalSize: (cols: Int, rows: Int)? {
        if case .tui(_, let cols, let rows) = self { (cols, rows) } else { nil }
    }

    /// Whether this client is the one the terminal is drawn for.
    public func controlled(by client: String?) -> Bool {
        guard let controller, let client, !client.isEmpty else { return false }
        return controller == client
    }
}

extension SessionMode: Codable {
    private enum CodingKeys: String, CodingKey { case kind, controller, cols, rows }

    public init(from decoder: Decoder) throws {
        // Older stores wrote a bare string. A terminal needs a client and
        // a window, and neither survives a restart, so it comes back chat.
        if let single = try? decoder.singleValueContainer(), let _ = try? single.decode(String.self) {
            self = .chat
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decodeIfPresent(String.self, forKey: .kind) == "tui",
              let controller = try c.decodeIfPresent(String.self, forKey: .controller),
              let cols = try c.decodeIfPresent(Int.self, forKey: .cols),
              let rows = try c.decodeIfPresent(Int.self, forKey: .rows)
        else {
            self = .chat
            return
        }
        self = .tui(controller: controller, cols: cols, rows: rows)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .chat:
            try c.encode("chat", forKey: .kind)
        case .tui(let controller, let cols, let rows):
            try c.encode("tui", forKey: .kind)
            try c.encode(controller, forKey: .controller)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
        }
    }
}
