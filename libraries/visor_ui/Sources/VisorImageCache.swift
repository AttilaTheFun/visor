import AgentUI
import SwiftUI
#if os(iOS) || os(macOS)
import Foundation
#endif
import VisorClient

/// What has already been fetched. Small and bounded: a transcript shows a
/// handful of pictures, and holding a screenshot twice is what would hurt.
@MainActor
final class VisorImageCache {
    static let shared = VisorImageCache()
    private var entries: [String: String] = [:]
    private var order: [String] = []
    private let limit = 24

    func data(for key: String) -> String? { entries[key] }

    func put(_ data: String, for key: String) {
        if entries[key] == nil { order.append(key) }
        entries[key] = data
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}
