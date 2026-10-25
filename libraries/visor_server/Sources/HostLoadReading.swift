/// What this computer's processors and memory are doing, read the way its
/// system tells it (`ServerPlatform.load`).
public protocol HostLoadReading: Sendable {
    /// The processors' time so far and the memory in use now; nil when the
    /// system does not say.
    func sample() -> HostLoadSample?
}
