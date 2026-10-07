// What a computer is called: the server's own name, as a sign-in gives
// it, unless the user named it themselves — then their name stays
// across sign-ins, and an empty name follows the server's again.

@testable import VisorClient
import VisorProtocol
import XCTest

final class RecordNameTests: XCTestCase {
    func testTheUsersNameOutlastsTheServers() {
        var record = AgentServerRecord(name: "", address: "http://10.0.0.2:7433")
        record.takeServerName("Logan's Mac Mini")
        XCTAssertEqual(record.name, "Logan's Mac Mini")
        XCTAssertFalse(record.renamed)

        record.rename(to: "  Mini  ")
        XCTAssertEqual(record.name, "Mini")
        XCTAssertTrue(record.renamed)
        record.takeServerName("Logan's Mac Mini")
        XCTAssertEqual(record.name, "Mini", "the sign-in's name does not replace the user's")

        // Saved and read back, the choice holds.
        let read = AgentServerRecord(json: record.json)
        XCTAssertEqual(read?.name, "Mini")
        XCTAssertEqual(read?.renamed, true)
        // A record from before the field is the server's to name.
        XCTAssertEqual(AgentServerRecord(json: .object(["id": .string("x"), "address": .string("a"), "name": .string("Old")]))?.renamed, false)

        record.rename(to: "")
        XCTAssertFalse(record.renamed)
        record.takeServerName("Logan's Mac Mini")
        XCTAssertEqual(record.name, "Logan's Mac Mini")
    }
}
