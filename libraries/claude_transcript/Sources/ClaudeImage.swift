import Foundation

/// A picture inside a message: the bytes as Claude Code stores them.
public struct ClaudeImage: Sendable, Equatable {
    public let base64: String
    public let mediaType: String?
    public init(base64: String, mediaType: String?) {
        self.base64 = base64
        self.mediaType = mediaType
    }
}
