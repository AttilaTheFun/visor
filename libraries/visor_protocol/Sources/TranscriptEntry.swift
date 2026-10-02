#if canImport(Foundation)
import Foundation
#endif

/// One transcript row: what AgentUI's TranscriptMessage carries, on the wire.
public struct TranscriptEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, tool }

    public var id: String
    public var role: Role
    public var text: String
    /// An assistant turn's tool calls, as activity labels ("Bash: ls").
    public var activities: [String]
    /// A tool result's tool name.
    public var toolName: String?
    /// Pictures that came with this row, as paths on the computer: a
    /// screenshot the agent took, an image it was shown. The client asks
    /// the computer for the bytes when it draws them.
    public var images: [String] = []
    /// Each picture's size in pixels, in the order of `images`, so a row
    /// can be laid out at its final size before the bytes arrive — a
    /// transcript that reshapes itself as each picture lands is a
    /// transcript that jumps. Shorter than `images` when a size is not
    /// known (a picture the computer could not read).
    public var imageSizes: [ImageSize] = []

    public init(id: String, role: Role, text: String, activities: [String] = [], toolName: String? = nil,
                images: [String] = [], imageSizes: [ImageSize] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.activities = activities
        self.toolName = toolName
        self.images = images
        self.imageSizes = imageSizes
    }

    /// Tolerant of a file written by a build that knew fewer fields, for
    /// the same reason SessionInfo is.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .assistant
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        activities = try c.decodeIfPresent([String].self, forKey: .activities) ?? []
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
        imageSizes = try c.decodeIfPresent([ImageSize].self, forKey: .imageSizes) ?? []
    }
}
