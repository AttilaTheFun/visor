import Foundation
import VisorServer

/// What the command-line server asks of the system it runs on, beyond what
/// the server itself does (ServerPlatform): where it keeps things before a
/// platform is made, how it starts a copy of itself in the background, how
/// it hears it is asked to stop, and how it puts a new build in its place.
public protocol CommandLineSystem: Sendable {
    /// The server's platform here, its lines going to `log`, replaced and
    /// ended through `lifecycle`.
    func platform(log: @escaping @Sendable (String) -> Void, lifecycle: any ServerLifecycle) -> ServerPlatform
    /// Where the server keeps what it keeps: sessions, secrets, its log.
    var dataDirectory: URL { get }
    /// This program's own file.
    var executable: String { get }
    /// Starts `executable` with `arguments` apart from this process and any
    /// terminal, its output appended to the file at `log`. Its process id.
    func startDetached(_ executable: String, _ arguments: [String], log: String) throws -> Int32
    /// Calls `stop` (once) when this process is asked to stop: Ctrl-C, or
    /// the system's request, from then on.
    @MainActor func onStop(_ stop: @escaping @Sendable () -> Void)
    /// Puts the program at `build` where `executable` is, while this one
    /// runs. What went wrong, or nil.
    func install(_ build: String, over executable: String) -> String?
}
