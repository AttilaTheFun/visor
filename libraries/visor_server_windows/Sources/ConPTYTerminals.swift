import Foundation
import VisorServer

/// Terminals as Windows has them: a pseudo console (ConPTY), the program
/// attached to it.
public struct ConPTYTerminals: TerminalLaunching {
    public init() {}

    @MainActor
    public func start(_ command: ShellCommand, directory: String, environment: [String: String], cols: Int, rows: Int) throws
        -> any TerminalChild {
        try ConPTYChild(command, directory: directory, environment: environment, cols: cols, rows: rows)
    }
}
