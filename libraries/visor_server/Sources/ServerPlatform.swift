// What the server takes from the system it runs on, given once at launch
// by the binary that runs it: the menu bar app on a Mac, the command-line
// server on Linux or Windows. Everything else the server does is the same
// everywhere, and this library asks nothing of the system except through
// what is given here.

import ClaudeTranscript
import Foundation
import Synchronization

public struct ServerPlatform: Sendable {
    /// Listening on loopback, and the connections that arrive.
    public var listening: any Listening
    /// Programs started on a pseudo-terminal: a terminal session's shell.
    public var terminals: any TerminalLaunching
    /// Signals to processes by id, and what a process is.
    public var processes: any ProcessSignals
    /// Where the password and the push key are kept.
    public var secrets: any SecretStore
    /// Requests to other computers' servers, and to APNs.
    public var fetching: any HTTPFetching
    /// Signing pushes with the owner's APNs key; nil where pushes are not
    /// sent.
    public var pushSigning: (any PushSigning)?
    /// A picture's size, read from its header.
    public var images: any ImageMeasuring
    /// Word of a followed file being written.
    public var files: any FileWatching
    /// Where the agents' tools are, and the user's shell.
    public var tools: any ToolLocating
    /// This computer: its name, and where the server keeps what it keeps.
    public var host: HostDetails
    /// Relaunching into another build, and quitting.
    public var lifecycle: any ServerLifecycle
    /// What the server says it is doing, a line at a time.
    public var log: @Sendable (String) -> Void
    /// SSH to peers, where the system has it (PeerSSH); nil elsewhere.
    public var ssh: (any PeerSSH)?

    public init(listening: any Listening, terminals: any TerminalLaunching, processes: any ProcessSignals,
                secrets: any SecretStore, fetching: any HTTPFetching, pushSigning: (any PushSigning)?,
                images: any ImageMeasuring, files: any FileWatching, tools: any ToolLocating, host: HostDetails,
                lifecycle: any ServerLifecycle,
                log: @escaping @Sendable (String) -> Void, ssh: (any PeerSSH)? = nil) {
        self.listening = listening
        self.terminals = terminals
        self.processes = processes
        self.secrets = secrets
        self.fetching = fetching
        self.pushSigning = pushSigning
        self.images = images
        self.files = files
        self.tools = tools
        self.host = host
        self.lifecycle = lifecycle
        self.log = log
        self.ssh = ssh
    }

    private static let given = Mutex<ServerPlatform?>(nil)

    /// The platform the binary gave. Asking before one was given is a
    /// mistake in the binary, and stops it.
    public static var current: ServerPlatform {
        get {
            guard let platform = given.withLock({ $0 }) else { fatalError("The server was used before ServerPlatform.current was set") }
            return platform
        }
        set { given.withLock { $0 = newValue } }
    }
}
