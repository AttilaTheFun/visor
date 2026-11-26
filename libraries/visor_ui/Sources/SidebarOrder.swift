import Foundation
import VisorProtocol

/// The sidebar's order (Logan, 26 Nov 2026): its computers by name, as
/// Finder sorts names (case aside, numbers by value, in the person's
/// language); in each, the sessions pinned on top in the order they were
/// pinned, the first pinned first, so an unpin and a pin again moves one
/// to the last of them; then the rest, the latest activity first.
enum SidebarOrder {
    /// Whether the computer named `a` lists before the one named `b`.
    static func computer(_ a: String, before b: String) -> Bool {
        let order = a.localizedStandardCompare(b)
        return order == .orderedSame ? a < b : order == .orderedAscending
    }

    /// Whether session `a` lists before `b` under their computer.
    static func session(_ a: SessionInfo, before b: SessionInfo) -> Bool {
        switch (a.pinnedAt, b.pinnedAt) {
        case let (first?, second?): first == second ? a.id < b.id : first < second
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): (a.updated ?? a.created) > (b.updated ?? b.created)
        }
    }
}
