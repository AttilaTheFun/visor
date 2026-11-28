import Foundation
import VisorProtocol

/// The sidebar's order (Logan, 26 Nov 2026): by name everywhere, so a row
/// never moves when something happens in it. Its computers by name; in
/// each, the pinned sessions first, then the rest, each by title. Names
/// as Finder sorts them (case aside, numbers by value, in the person's
/// language), and the same name in another case, or twice, by id, so the
/// order is total.
enum SidebarOrder {
    /// Whether the computer named `a` lists before the one named `b`.
    static func computer(_ a: String, before b: String) -> Bool {
        let order = compare(a, b)
        return order == .orderedSame ? a < b : order == .orderedAscending
    }

    /// Whether session `a` lists before `b` under their computer.
    static func session(_ a: SessionInfo, before b: SessionInfo) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        let order = compare(title(a), title(b))
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }

    /// Finder's comparison without its forced ordering: Apple's
    /// localizedStandardCompare puts "same" before "Same" (Linux's calls
    /// them the same), so the same name in another case is left to the id
    /// on every platform.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .numeric, .widthInsensitive], range: nil, locale: .current)
    }

    /// The name a row shows: its title, or its agent's.
    static func title(_ session: SessionInfo) -> String { session.title.isEmpty ? session.agent.title : session.title }
}
