import Foundation
import VisorProtocol

/// A device that asked for pushes.
struct PushDevice: Codable, Equatable {
    let token: String
    let platform: String
    let environment: String
    let topic: String
    var registered: Double
    /// The kinds of push it doesn't want (`PushKind`'s raw values); nil, as
    /// an older client registers, is none. A silent state push still goes.
    var muted: [String]? = nil

    /// Whether a push of this kind goes to it: nil for a silent one.
    func wants(_ kind: String?) -> Bool {
        guard let kind else { return true }
        return !(muted ?? []).contains(kind)
    }
}
