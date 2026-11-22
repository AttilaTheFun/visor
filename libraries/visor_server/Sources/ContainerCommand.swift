// A command run to its end in the Sessions container (SessionsContainer.run):
// what the server would otherwise run on this Mac as `claude -p`, when the
// container is on (docs/containers.md, Containers only): Super Compact's
// calls and the models' `initialize`, so a Mac used with the container alone
// has no Claude Code of its own writing ~/.claude, ~/.claude.json or the
// keychain's credentials.

import Foundation

public struct ContainerCommand: Sendable {
    /// Its argv, the program found on the image's PATH (`claude`).
    public var arguments: [String]
    /// Set over the image's environment.
    public var environment: [String: String]
    /// Its standard input, then closed; nil: none.
    public var input: Data?
    /// Its working folder (one the container shares at the same path); nil:
    /// the Sessions volume.
    public var workingDirectory: String?
    /// How long it may take before it's ended.
    public var limit: Duration
    /// Asked while it runs: once true, it's ended, and `stopped` says so.
    public var stopping: @Sendable () -> Bool
    /// Asked of what it has written so far: once true, it's ended as done
    /// (an answer read, with nothing more wanted of it).
    public var answered: @Sendable (String) -> Bool

    public init(arguments: [String], environment: [String: String] = [:], input: Data? = nil, workingDirectory: String? = nil,
                limit: Duration, stopping: @escaping @Sendable () -> Bool = { false },
                answered: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.arguments = arguments
        self.environment = environment
        self.input = input
        self.workingDirectory = workingDirectory
        self.limit = limit
        self.stopping = stopping
        self.answered = answered
    }
}
