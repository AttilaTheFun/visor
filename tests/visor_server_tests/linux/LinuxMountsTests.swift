// The folders a container's computer shares with it, from its mount table:
// those mounted writable over virtiofs (Apple's container), 9p or gRPC FUSE,
// at their mount points; not the container's own disks, nor a read-only
// share such as Visor's programs.

@testable import VisorServerLinux
import Foundation
import Testing

extension ServerTests {
@Suite final class LinuxMountsTests {
    @Test func testTheSharedFoldersAreTheWritableSharesFromTheComputer() {
        let table = """
        1 0 254:16 / / rw,relatime - ext4 /dev/vdb rw
        2 1 254:32 / /root rw,relatime - ext4 /dev/vdc rw
        3 1 0:40 / /opt/visor-server ro,relatime - virtiofs virtiofs ro
        4 1 254:48 / /var/cache/bazel rw,relatime - ext4 /dev/vdd rw
        5 1 0:41 / /Users/logan/Developer rw,relatime - virtiofs virtiofs rw
        6 1 0:42 / /Users/logan/My\\040Work rw,relatime shared:3 - 9p share rw
        7 1 0:5 / /proc rw,nosuid - proc proc rw
        """
        #expect(LinuxMounts.shared(mountinfo: table) == ["/Users/logan/Developer", "/Users/logan/My Work"])
        #expect(LinuxMounts.shared(mountinfo: "") == [])
    }
}
}
