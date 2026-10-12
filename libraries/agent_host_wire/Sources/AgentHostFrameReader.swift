import Foundation

/// Frames out of bytes as they arrive, however the bytes are cut up.
public struct AgentHostFrameReader: Sendable {
    private var buffer = Data()

    /// The largest frame taken: anything claiming more is not a frame, and
    /// ends the connection.
    public static let largest = 64 << 20

    public init() {}

    /// The frames these bytes complete; nil when the bytes are not frames.
    public mutating func take(_ data: Data) -> [AgentHostFrame]? {
        buffer.append(data)
        var frames: [AgentHostFrame] = []
        var start = buffer.startIndex
        while buffer.endIndex - start >= 5 {
            let length = Int(AgentHostFrame.number(buffer[start + 1 ..< start + 5]))
            guard length <= Self.largest else { return nil }
            guard buffer.endIndex - start >= 5 + length else { break }
            let kind = buffer[start]
            if let frame = AgentHostFrame(kind: kind, payload: Data(buffer[start + 5 ..< start + 5 + length])) { frames.append(frame) }
            start += 5 + length
        }
        buffer = Data(buffer[start...])
        return frames
    }
}
