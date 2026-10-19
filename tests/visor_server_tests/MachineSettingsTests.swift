// The virtual machines a server may run agents' sessions in: none by
// default, at most what the system allows of each platform, and kept as
// set, with the provisioning script; a file from before reads as none.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

final class MachineSettingsTests: XCTestCase {
    func testNoneByDefaultAndAFileFromBeforeReadsAsNone() throws {
        XCTAssertTrue(MachinePlatform.allCases.allSatisfy { ServerSettings().maxMachines($0) == 0 })
        let before = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"lan":true}"#.utf8))
        XCTAssertEqual(before.maxMachines(.macos), 0)
        XCTAssertEqual(before.provisioningScript, "")
    }

    func testKeptAsSetWithinWhatTheSystemAllows() throws {
        var settings = ServerSettings()
        settings.setMaxMachines(.macos, 5)
        settings.setMaxMachines(.linux, 4)
        settings.provisioningScript = "/opt/acme/provision"
        XCTAssertEqual(settings.maxMachines(.macos), 2, "two macOS machines per Mac")

        let read = try JSONDecoder().decode(ServerSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(read.maxMachines(.macos), 2)
        XCTAssertEqual(read.maxMachines(.linux), 4)
        XCTAssertEqual(read.provisioningScript, "/opt/acme/provision")

        settings.setMaxMachines(.linux, 0)
        XCTAssertNil(settings.machines["linux"], "0 takes the platform off")
    }
}
