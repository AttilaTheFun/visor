/// A socket at a socket file that is gone: no more events will come.
public struct SocketFileSocketGone: Error, Sendable {
    public init() {}
}
