// The host's home folder is $VISOR_HOME_FOLDER when it is set: the
// picker starts there and a session given no folder works there. Other
// paths have their "~" expanded as always.

import Foundation
@testable import VisorServer
import VisorSystem
import Testing

extension ServerTests {
@Suite final class HostFoldersTests {
    @Test func testTheHomeFolderIsTheOneGiven() {
        let given = ["VISOR_HOME_FOLDER": "/work/projects"]
        #expect(HostFolders.home(given) == "/work/projects")
        #expect(HostFolders.resolve("", environment: given) == "/work/projects")
        #expect(HostFolders.resolve("~", environment: given) == "/work/projects")
        #expect(HostFolders.resolve("~/code", environment: given) == ((NSHomeDirectory() as NSString).appendingPathComponent("code")))
        #expect(HostFolders.resolve("/tmp/x", environment: given) == "/tmp/x")
    }

    @Test func testWithoutItTheHomeFolderIsTheUsers() {
        #expect(HostFolders.home([:]) == NSHomeDirectory())
        #expect(HostFolders.resolve("", environment: [:]) == NSHomeDirectory())
        #expect(HostFolders.resolve("~", environment: [:]) == NSHomeDirectory())
        #expect(HostFolders.home(["VISOR_HOME_FOLDER": "~/sandbox"]) == ((NSHomeDirectory() as NSString).appendingPathComponent("sandbox")))
    }
}
}
