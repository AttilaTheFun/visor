import Foundation
import Synchronization
import VisorProtocol

/// A process on a PTY (a terminal session's shell): it takes what the
/// user types and can be resized.
@MainActor
public protocol TerminalCapable: AnyObject {
    func write(_ data: Data)
    func resize(cols: Int, rows: Int)
    /// Ctrl-C.
    func interrupt()
    /// Makes what runs on it draw its whole screen again: how a window
    /// that has just attached is given the truth.
    func repaint()
    /// Launches it now; a terminal is live before anything is typed.
    func start() throws
}
