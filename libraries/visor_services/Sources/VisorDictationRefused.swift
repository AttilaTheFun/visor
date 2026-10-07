/// Why dictation did not start: the words the composer could show.
public struct VisorDictationRefused: Error, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}
