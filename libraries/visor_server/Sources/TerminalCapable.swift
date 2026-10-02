import Foundation
import Synchronization
import VisorProtocol

/// A process on a PTY: it takes what the user types and can be resized.
@MainActor
public protocol TerminalCapable: AnyObject {
    func write(_ data: Data)
    func resize(cols: Int, rows: Int)
    /// The agent's own interrupt of the turn in flight (Escape).
    func interrupt()
    /// Makes the agent draw its whole screen again. A full-screen
    /// interface owns every cell and repaints on its own terms, so this
    /// is how a window that has just attached is given the truth.
    func repaint()
    /// Whether the agent is at its input box, rather than a startup or
    /// permission prompt that typed text would answer with its default.
    var ready: Bool { get }
    /// Launches it now; a terminal is live before anything is said.
    func start() throws
}
