// What the code below the server (the agents' tools, processes, folders and
// pictures) takes from the system it runs on, given once at launch. The
// server's own platform (ServerPlatform, in visor_server) carries these
// pieces with the rest and installs them here when it is given, so a binary
// that gives the server its platform gives this one too.

import ClaudeTranscript
import Foundation
import Synchronization

public struct SystemPlatform: Sendable {
    /// Where the agents' tools are.
    public var tools: any ToolLocating
    /// Signals to processes by id, and what a process is.
    public var processes: any ProcessSignals
    /// This computer: its name, and where what is kept is kept.
    public var host: HostDetails
    /// A picture's size, read from its header.
    public var images: any ImageMeasuring
    /// Word of a followed file being written.
    public var files: any FileWatching
    /// Hosts the agents run under, apart from the server; nil where they
    /// are the server's own children.
    public var agentHosts: (any AgentHosting)?
    /// What is being done, a line at a time.
    public var log: @Sendable (String) -> Void

    public init(tools: any ToolLocating, processes: any ProcessSignals, host: HostDetails, images: any ImageMeasuring,
                files: any FileWatching, agentHosts: (any AgentHosting)? = nil, log: @escaping @Sendable (String) -> Void) {
        self.tools = tools
        self.processes = processes
        self.host = host
        self.images = images
        self.files = files
        self.agentHosts = agentHosts
        self.log = log
    }

    private static let given = Mutex<SystemPlatform?>(nil)

    /// The platform the binary gave (through ServerPlatform.current, or
    /// itself). Asking before one was given is a mistake in the binary, and
    /// stops it.
    public static var current: SystemPlatform {
        get {
            guard let platform = given.withLock({ $0 }) else { fatalError("The system was used before SystemPlatform.current was set") }
            return platform
        }
        set { given.withLock { $0 = newValue } }
    }
}
