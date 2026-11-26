// The sidebar's order: computers by name, as Finder sorts names; under
// each, the pinned sessions first in the order they were pinned, then the
// rest, the latest first.

import VisorProtocol
@testable import VisorUI
import XCTest

@MainActor
final class SidebarOrderTests: XCTestCase {
    private func session(_ id: String, updated: Double, pinnedAt: Double? = nil) -> SessionInfo {
        var info = SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: id, created: 0)
        info.updated = updated
        info.pinnedAt = pinnedAt
        return info
    }

    private func ordered(_ sessions: [SessionInfo]) -> [String] {
        sessions.sorted { SidebarOrder.session($0, before: $1) }.map(\.id)
    }

    func testPinnedFirstByWhenTheyWerePinned() {
        let sessions = [
            session("latest", updated: 500),
            session("pinned second", updated: 10, pinnedAt: 200),
            session("older", updated: 100),
            session("pinned first", updated: 400, pinnedAt: 100),
            session("pinned last", updated: 1, pinnedAt: 300),
        ]
        XCTAssertEqual(ordered(sessions), ["pinned first", "pinned second", "pinned last", "latest", "older"])
    }

    func testUnpinnedAndPinnedAgainGoesLastOfThePinned() {
        var sessions = [session("a", updated: 1, pinnedAt: 100), session("b", updated: 2, pinnedAt: 200), session("c", updated: 3)]
        sessions[0].pinnedAt = nil
        XCTAssertEqual(ordered(sessions), ["b", "c", "a"], "unpinned: among the rest by its activity")
        sessions[0].pinnedAt = 300
        XCTAssertEqual(ordered(sessions), ["b", "a", "c"])
    }

    func testNoPinsIsTheLatestFirst() {
        var never = session("never", updated: 0)
        never.updated = nil
        never.created = 50
        XCTAssertEqual(ordered([session("x", updated: 10), session("y", updated: 90), never]), ["y", "never", "x"])
    }

    func testComputersAlphabetically() {
        let names = ["mini", "Studio", "mac 10", "Mac 2", "Échelle", "zeta", "air"]
        let sorted = names.sorted { SidebarOrder.computer($0, before: $1) }
        XCTAssertEqual(sorted, ["air", "Échelle", "Mac 2", "mac 10", "mini", "Studio", "zeta"])
    }

    func testTheSameNameInAnyCaseHasAnOrderStill() {
        XCTAssertNotEqual(SidebarOrder.computer("Mini", before: "mini"), SidebarOrder.computer("mini", before: "Mini"))
    }
}
