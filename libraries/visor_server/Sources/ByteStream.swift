import Foundation

/// One connection's bytes, both ways, as the system carries them. All of it
/// on the main actor: what arrives is handed over in order.
@MainActor
public protocol ByteStream: AnyObject {
    /// Starts reading: each chunk as it arrives, then nil once, when the
    /// other end has gone or the connection failed.
    func receive(_ chunk: @escaping @MainActor (Data?) -> Void)
    /// Sends `data`; `sent` once it has gone out, or could not.
    func send(_ data: Data, sent: (@MainActor () -> Void)?)
    /// Closes the connection. Nothing more is received.
    func close()
}
