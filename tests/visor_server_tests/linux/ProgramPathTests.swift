// Where a Linux server is: /proc/self/exe, which says "<path> (deleted)"
// once the file the server was started from has been replaced, as an
// update or a build copied in by hand replaces it. Its successor is started
// from the path itself, where the new build is.

@testable import VisorServerLinux
import Foundation
import Testing

extension ServerTests {
@Suite final class ProgramPathTests {
    @Test func testAReplacedProgramIsAtItsPath() {
        #expect((LinuxSystem.program(at: "/usr/local/bin/visor-server (deleted)")) == "/usr/local/bin/visor-server")
    }

    @Test func testAProgramInPlaceIsAsLinked() {
        #expect(LinuxSystem.program(at: "/usr/local/bin/visor-server") == "/usr/local/bin/visor-server")
    }
}
}
