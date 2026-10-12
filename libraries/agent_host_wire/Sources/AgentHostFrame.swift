// What the server and an agent's host say to each other over the host's
// socket. The host runs one agent apart from the server, so the server can
// restart (or crash) and the agent carries on: it keeps what the agent
// said, numbered by line, and a server that connects again picks up where
// it left off. Each frame is a kind byte, a four-byte length (big-endian)
// and that many bytes.

import Foundation

public enum AgentHostFrame: Equatable, Sendable {
    // MARK: From the host

    /// The first word on every connection: the agent and what the host
    /// still has of what it said.
    case hello(AgentHostHello)
    /// One line of the agent's output, without its newline, and its number
    /// (the first is 0).
    case line(UInt64, Data)
    /// Some of what the agent wrote to its errors.
    case errors(Data)
    /// The agent has gone: its status, and whether a signal ended it.
    case exited(status: Int32, signaled: Bool)
    /// Something the host did to the agent that its session is told, such
    /// as stopping a command that used too much memory.
    case notice(String)
    /// How much memory the agent and what it runs are using, in bytes.
    case memory(UInt64)

    // MARK: From the server

    /// The server is here: the lines from `from` on are sent, then each as
    /// the agent says it.
    case attach(from: UInt64)
    /// Bytes for the agent's input.
    case input(Data)
    /// End of the agent's input.
    case closeInput
    /// A request to end (SIGTERM) or no choice (SIGKILL, to everything the
    /// agent runs too).
    case signal(Signal)
    /// The most memory the agent and what it runs may use, in bytes; 0 is
    /// no limit.
    case limit(UInt64)
    /// The server has heard the agent's exit: the host can go.
    case release

    public enum Signal: UInt8, Sendable {
        case terminate = 1
        case kill = 2
    }

    /// The frame's bytes on the wire.
    public var encoded: Data {
        let (kind, payload) = parts
        var data = Data([kind])
        data.append(Self.bigEndian(UInt32(payload.count)))
        data.append(payload)
        return data
    }

    private var parts: (UInt8, Data) {
        switch self {
        case .hello(let hello): return (1, (try? JSONEncoder().encode(hello)) ?? Data())
        case .line(let number, let text): return (2, Self.bigEndian(number) + text)
        case .errors(let text): return (3, text)
        case .exited(let status, let signaled): return (4, Self.bigEndian(UInt32(bitPattern: status)) + Data([signaled ? 1 : 0]))
        case .notice(let text): return (5, Data(text.utf8))
        case .memory(let bytes): return (6, Self.bigEndian(bytes))
        case .attach(let from): return (20, Self.bigEndian(from))
        case .input(let data): return (21, data)
        case .closeInput: return (22, Data())
        case .signal(let signal): return (23, Data([signal.rawValue]))
        case .limit(let bytes): return (24, Self.bigEndian(bytes))
        case .release: return (25, Data())
        }
    }

    /// The frame of this kind with this payload; nil for a kind this build
    /// does not know (a newer host's or server's), which is skipped.
    init?(kind: UInt8, payload: Data) {
        switch kind {
        case 1:
            guard let hello = try? JSONDecoder().decode(AgentHostHello.self, from: payload) else { return nil }
            self = .hello(hello)
        case 2:
            guard payload.count >= 8 else { return nil }
            self = .line(Self.number(payload.prefix(8)), Data(payload.dropFirst(8)))
        case 3: self = .errors(payload)
        case 4:
            guard payload.count >= 5 else { return nil }
            self = .exited(status: Int32(bitPattern: UInt32(truncatingIfNeeded: Self.number(payload.prefix(4)))),
                           signaled: payload[payload.startIndex + 4] != 0)
        case 5: self = .notice(String(decoding: payload, as: UTF8.self))
        case 6:
            guard payload.count >= 8 else { return nil }
            self = .memory(Self.number(payload.prefix(8)))
        case 20:
            guard payload.count >= 8 else { return nil }
            self = .attach(from: Self.number(payload.prefix(8)))
        case 21: self = .input(payload)
        case 22: self = .closeInput
        case 23:
            guard let byte = payload.first, let signal = Signal(rawValue: byte) else { return nil }
            self = .signal(signal)
        case 24:
            guard payload.count >= 8 else { return nil }
            self = .limit(Self.number(payload.prefix(8)))
        case 25: self = .release
        default: return nil
        }
    }

    static func bigEndian<Value: FixedWidthInteger>(_ value: Value) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// The big-endian number in these bytes.
    static func number(_ bytes: Data) -> UInt64 {
        bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }
}
