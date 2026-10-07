/// What SSH refuses.
public enum SSHError: Error, Equatable, Sendable {
    /// The computer was not reached: no answer, no SSH there.
    case unreachable(String)
    /// A computer's key is not the one seen before.
    case hostKeyChanged
    /// A computer did not take the key offered.
    case keyRefused
}
