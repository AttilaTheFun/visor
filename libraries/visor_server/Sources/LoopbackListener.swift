/// A port being listened on.
@MainActor
public protocol LoopbackListener: AnyObject {
    /// Stops listening. The connections already accepted go on.
    func stop()
}
