/// A port being listened on.
@MainActor
public protocol Listener: AnyObject {
    /// Stops listening. The connections already accepted go on.
    func stop()
}
