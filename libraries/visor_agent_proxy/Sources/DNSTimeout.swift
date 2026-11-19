// An upstream resolver that didn't answer in time.

/// An upstream that didn't answer in time: the forwarder asks the next.
public struct DNSTimeout: Error, Equatable {
    public init() {}
}
