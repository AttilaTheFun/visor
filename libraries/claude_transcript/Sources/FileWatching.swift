import Foundation

/// The system's word on a file as it is written: how a followed log learns
/// there is more to read.
public protocol FileWatching: Sendable {
    /// `true` each time the file at `url` is written to, `false` once when
    /// it is deleted or renamed, after which nothing more is said. Nil when
    /// the file cannot be opened. Writes that come faster than they are
    /// read may be one `true`.
    func changes(to url: URL) -> AsyncStream<Bool>?
}
