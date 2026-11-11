/// A program and its arguments, as it is started.
public struct ShellCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    public init(_ executable: String, _ arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }
}
