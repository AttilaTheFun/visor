import Foundation

/// What a command run in a container said: its status, its standard output
/// and its errors.
public struct ContainerExec: Sendable {
    public var status: Int32
    public var output: String
    public var errors: String

    public init(status: Int32, output: String, errors: String = "") {
        self.status = status
        self.output = output
        self.errors = errors
    }

    /// Its words for a person: errors, else output.
    public var said: String {
        let text = errors.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}
