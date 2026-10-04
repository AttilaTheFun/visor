import Foundation

/// A program running on a pseudo-terminal.
@MainActor
public protocol TerminalChild: AnyObject {
    var processID: Int32 { get }
    /// What it draws, as it draws it. Ends once it has exited.
    var output: AsyncStream<Data> { get }
    /// Whether it has exited.
    var hasExited: Bool { get }
    /// Returns once it has exited.
    func exited() async
    /// Tells the terminal its shape.
    func resize(cols: Int, rows: Int)
    /// What was typed.
    func write(_ data: Data)
    /// Ends it and returns when it is gone: asked to end, and after
    /// `grace` given no choice.
    func end(grace: Duration) async
}
