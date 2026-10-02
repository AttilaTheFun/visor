#if canImport(Foundation)
import Foundation
#endif

/// A picture's size in pixels.
public struct ImageSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}
