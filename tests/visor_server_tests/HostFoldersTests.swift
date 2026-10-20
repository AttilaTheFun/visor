// The host's home folder is $VISOR_HOME_FOLDER when it is set: the
// picker starts there and a session given no folder works there. Other
// paths have their "~" expanded as always.

import Foundation
@testable import VisorServer
import XCTest

final class HostFoldersTests: XCTestCase {
    func testTheHomeFolderIsTheOneGiven() {
        let given = ["VISOR_HOME_FOLDER": "/work/projects"]
        XCTAssertEqual(HostFolders.home(given), "/work/projects")
        XCTAssertEqual(HostFolders.resolve("", environment: given), "/work/projects")
        XCTAssertEqual(HostFolders.resolve("~", environment: given), "/work/projects")
        XCTAssertEqual(HostFolders.resolve("~/code", environment: given), (NSHomeDirectory() as NSString).appendingPathComponent("code"))
        XCTAssertEqual(HostFolders.resolve("/tmp/x", environment: given), "/tmp/x")
    }

    func testWithoutItTheHomeFolderIsTheUsers() {
        XCTAssertEqual(HostFolders.home([:]), NSHomeDirectory())
        XCTAssertEqual(HostFolders.resolve("", environment: [:]), NSHomeDirectory())
        XCTAssertEqual(HostFolders.resolve("~", environment: [:]), NSHomeDirectory())
        XCTAssertEqual(HostFolders.home(["VISOR_HOME_FOLDER": "~/sandbox"]), (NSHomeDirectory() as NSString).appendingPathComponent("sandbox"))
    }
}
