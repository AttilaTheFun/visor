import Foundation

/// The tokens a request carried; what the context holds right now.
public struct ClaudeUsage: Sendable, Equatable {
    public let input: Int
    public let cacheCreation: Int
    public let cacheRead: Int
    public let output: Int
    public var contextUsed: Int { input + cacheCreation + cacheRead }
    public init(input: Int, cacheCreation: Int, cacheRead: Int, output: Int) {
        self.input = input
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.output = output
    }
}
