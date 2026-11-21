// A process to run in the container: its arguments, its environment over
// the image's, its working folder, and the file its standard output and
// error go to (appended).

import Foundation

public struct ContainerProcessSpec: Equatable, Sendable {
    /// Unique among the container's processes.
    public var id: String
    public var arguments: [String]
    /// Set over the image's own environment.
    public var environment: [String: String]
    /// Nil: the image's.
    public var workingDirectory: String?
    public var log: URL

    public init(id: String, arguments: [String], environment: [String: String] = [:], workingDirectory: String? = nil, log: URL) {
        self.id = id
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.log = log
    }
}
