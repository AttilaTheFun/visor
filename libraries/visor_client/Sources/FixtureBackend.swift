import VisorProtocol
import VisorServices

/// The canned computer's road.
public struct FixtureBackend: Backend {
    public static let name = "fixture"
    public let id = FixtureBackend.name
    public let title = "Snapshot"
    public let hostFieldTitle = "Host"
    public let hostPlaceholder = "snapshot.local"
    public let passwordFieldTitle = "Password"
    public init() {}
    public func makeTransport() -> any HostTransport { FixtureTransport() }
}
