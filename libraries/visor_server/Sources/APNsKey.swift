import Foundation
import VisorProtocol

/// The owner's APNs key: its PEM, its id, the team's.
struct APNsKey {
    let pem: String
    let keyID: String
    let teamID: String
}
