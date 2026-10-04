import Foundation
import VisorServer

/// Terminals as POSIX systems (macOS, Linux) have them: a pseudo-terminal,
/// the program the leader of a new session on it.
public struct POSIXTerminals: TerminalLaunching {
    public init() {}

    @MainActor
    public func start(_ command: ShellCommand, directory: String, environment: [String: String], cols: Int, rows: Int) throws
        -> any TerminalChild {
        try POSIXTerminalChild(command, directory: directory, environment: environment, cols: cols, rows: rows)
    }
}
