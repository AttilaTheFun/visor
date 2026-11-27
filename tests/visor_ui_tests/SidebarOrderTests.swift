// The sidebar's order: computers by name, as Finder sorts names; under
// each, the pinned sessions first, then the rest, each by title, and by
// id where titles are the same. Nothing that happens in a session moves
// its row.

import VisorProtocol
@testable import VisorUI
import XCTest

@MainActor
final class SidebarOrderTests: XCTestCase {
    private func session(_ id: String, _ title: String, pinned: Bool = false, updated: Double = 0) -> SessionInfo {
        var info = SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: title, created: 0)
        info.updated = updated
        info.pinned = pinned
        return info
    }

    private func ordered(_ sessions: [SessionInfo]) -> [String] {
        sessions.sorted { SidebarOrder.session($0, before: $1) }.map(\.id)
    }

    func testPinnedFirstThenTheRestEachByTitle() {
        let sessions = [
            session("w", "Widget layout", updated: 500),
            session("r", "Release notes", pinned: true, updated: 1),
            session("o", "offline sync", updated: 2),
            session("a", "API limits", pinned: true, updated: 900),
            session("b", "Backups 10"),
            session("c", "Backups 2"),
        ]
        XCTAssertEqual(ordered(sessions), ["a", "r", "c", "b", "o", "w"])
    }

    func testActivityMovesNoRow() {
        var sessions = [session("a", "Alpha", updated: 1), session("b", "Beta", updated: 2)]
        XCTAssertEqual(ordered(sessions), ["a", "b"])
        sessions[1].updated = 0
        sessions[0].updated = 1000
        sessions[1].busy = true
        XCTAssertEqual(ordered(sessions), ["a", "b"])
    }

    func testTheSameTitleGoesByIDAndNoTitleIsItsAgents() {
        XCTAssertEqual(ordered([session("2", "Same"), session("1", "Same"), session("3", "same")]), ["1", "2", "3"])
        let untitled = session("u", "")
        XCTAssertEqual(SidebarOrder.title(untitled), untitled.agent.title)
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
