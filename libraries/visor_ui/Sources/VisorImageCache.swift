import AgentUI
import SwiftUI
import VisorClient

/// What has already been fetched, and decoded. Small and bounded: a
/// transcript shows a handful of pictures, and holding a screenshot twice
/// is what would hurt.
@MainActor
final class VisorImageCache {
    static let shared = VisorImageCache()
    private var entries: [String: String] = [:]
    private var order: [String] = []
    private var pictures: [String: DecodedPicture] = [:]
    private var pictureOrder: [String] = []
    private let limit = 24

    func data(for key: String) -> String? { entries[key] }

    func put(_ data: String, for key: String) {
        Self.insert(data, for: key, into: &entries, order: &order, limit: limit)
    }

    func picture(for key: String) -> DecodedPicture? { pictures[key] }

    func put(_ picture: DecodedPicture, for key: String) {
        Self.insert(picture, for: key, into: &pictures, order: &pictureOrder, limit: limit)
    }

    private static func insert<Value>(_ value: Value, for key: String, into entries: inout [String: Value], order: inout [String], limit: Int) {
        if entries[key] == nil { order.append(key) }
        entries[key] = value
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}
