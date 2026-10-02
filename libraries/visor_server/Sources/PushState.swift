import CryptoKit
import Foundation
import VisorProtocol

/// What a session last looked like, for telling what changed.
struct PushState: Equatable {
    var busy = false
    var waiting = false
    var failed = false
    var goal: String?
    var goalSince: Double?
}
