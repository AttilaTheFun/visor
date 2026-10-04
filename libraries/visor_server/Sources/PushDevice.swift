import Foundation
import VisorProtocol

/// A device that asked for pushes.
struct PushDevice: Codable, Equatable {
    let token: String
    let platform: String
    let environment: String
    let topic: String
    var registered: Double
}
