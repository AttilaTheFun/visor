// How a build names its version: from 0.38 a build is a version of its
// own (MAJOR.MINOR.BUILD, its build number 1) and says only that; an
// older one says its version and build.

import VisorProtocol
import XCTest

final class VersionTitleTests: XCTestCase {
    func testABuildOfItsOwnSaysOnlyItsVersion() {
        XCTAssertEqual(VersionTitle.of(version: "0.38.7", build: "1"), "0.38.7")
        XCTAssertEqual(VersionTitle.of(version: "0.38.0", build: nil), "0.38.0")
    }

    func testAnOlderBuildSaysItsVersionAndBuild() {
        XCTAssertEqual(VersionTitle.of(version: "0.35", build: "21"), "0.35 (21)")
        XCTAssertEqual(VersionTitle.of(version: "0.35", build: nil), "0.35")
    }
}
