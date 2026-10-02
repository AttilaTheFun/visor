import VisorProtocol
import VisorServices

/// What comes back over the live channel.
public enum TransportEvent: Sendable {
    case opened
    case message(String)
    case closed(String)
}
