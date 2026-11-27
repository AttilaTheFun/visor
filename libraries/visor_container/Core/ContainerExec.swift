// A process to run in the Sessions container (ContainerEngine.exec): step 4
// runs each session's agent-wrapper so.

import Foundation

public struct ContainerExec: Equatable, Sendable {
    /// Unique among what runs in it (a session's id, say).
    public var id: String
    public var arguments: [String]
    /// Set over the image's environment.
    public var environment: [String: String]
    /// Nil: the image's working folder.
    public var workingDirectory: String?
    /// Where its standard output and error go (appended); nil:
    /// `sessions/logs/<id>.log` on the Visor volume (Containers/).
    public var log: URL?
    /// What it reads on its standard input, then the input's end (an
    /// agent's token, which agent-wrapper takes on AGENT_TOKEN_FD=0); nil:
    /// none. Never logged.
    public var input: Data?

    public init(id: String, arguments: [String], environment: [String: String] = [:], workingDirectory: String? = nil, log: URL? = nil,
                input: Data? = nil) {
        self.id = id
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.log = log
        self.input = input
    }
}
