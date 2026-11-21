// What a session's Migrate… offers (MigratePlaces): its computer's Sessions
// container while that takes sessions, its computer once it's placed there,
// and the other computers that migrate, but not for a session in the
// container, which moves back first (its turns there would be left behind).

@testable import VisorClient
import VisorProtocol
@testable import VisorUI
import XCTest

@MainActor
final class MigratePlacesTests: XCTestCase {
    private func session(_ placement: SessionPlacement) -> SessionInfo {
        var info = SessionInfo(id: "S", agent: .claude, cwd: "/Volumes/Sessions/Claude/S", title: "S", created: 0)
        info.placement = placement
        return info
    }

    private func computer(_ name: String, container: Bool = false) -> AgentServerConnection {
        let host = AgentServerConnection(record: AgentServerRecord(name: name, address: "http://127.0.0.1:1"))
        if container { host.container = ContainerStatus(state: .stopped, enabled: true, canRun: true) }
        return host
    }

    func testOnItsComputerTheContainerAndTheOthersAreOffered() {
        let places = MigratePlaces(session: session(.host), host: computer("Mini", container: true), others: [computer("MacBook")])
        XCTAssertTrue(places.intoContainer && !places.back && !places.elsewhereWaits)
        XCTAssertEqual(places.containerName, "Mini's Container")
        XCTAssertEqual(places.elsewhere.map(\.record.name), ["MacBook"])
        XCTAssertEqual(places.said, "It's on Mini.")
    }

    func testInTheContainerItsComputerIsOfferedAndTheOthersWait() {
        let places = MigratePlaces(session: session(.container), host: computer("Mini", container: true), others: [computer("MacBook")])
        XCTAssertTrue(places.back && !places.intoContainer && places.elsewhereWaits)
        XCTAssertEqual(places.elsewhere.map(\.record.name), ["MacBook"], "shown, disabled")
        XCTAssertTrue(places.said.hasPrefix("It's in Mini's Container. Move it back to Mini first"), places.said)
    }

    func testAContainerThatTakesNoSessionsIsNotOffered() {
        let places = MigratePlaces(session: session(.host), host: computer("Mini"), others: [])
        XCTAssertFalse(places.intoContainer || places.offers)
    }
}
