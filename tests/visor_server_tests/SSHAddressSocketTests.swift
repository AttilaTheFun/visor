// An SSH address with the server's socket file in it (`?socket=`, 0.66):
// the path read back as given, beside the jump hosts, and the command a
// client runs on it; without one, or with one `sh` would read more into,
// the places the socket file has been, in turn.

import VisorProtocol
import Testing

extension ServerTests {
@Suite struct SSHAddressSocketTests {
    private let group = "/Users/logan/Library/Group Containers/group.com.LoganShire.Visor/r/server.sock"

    @Test func theSocketIsReadBackAsGiven() throws {
        let address = try #require(SSHAddress("ssh://logan@mini.local?" + SSHAddress.socketQuery(group)))
        #expect(address.target == SSHAddress.Hop(user: "logan", host: "mini.local"))
        #expect(address.via.isEmpty)
        #expect(address.socket == group)
        #expect(address.attachCommand == "sh -c 'exec nc -U \"\(group)\"'")
    }

    @Test func itSitsBesideTheJumpHosts() throws {
        let address = try #require(SSHAddress("logan@mini:2222?via=me@jump&" + SSHAddress.socketQuery(group)))
        #expect(address.target == SSHAddress.Hop(user: "logan", host: "mini", port: 2222))
        #expect(address.via == [SSHAddress.Hop(user: "me", host: "jump")])
        #expect(address.socket == group)
    }

    @Test func withoutOneThePlacesAreTriedInTurn() throws {
        let address = try #require(SSHAddress("ssh://logan@mini.local"))
        #expect(address.socket == nil)
        #expect(address.attachCommand == SSHAddress.defaultAttachCommand)
        let command = SSHAddress.defaultAttachCommand
        let volume = try #require(command.range(of: "/Volumes/Visor/run/server.sock"))
        let container = try #require(command.range(of: "$HOME/Library/Group Containers/group.com.LoganShire.Visor/r/server.sock"))
        let home = try #require(command.range(of: "$HOME/.visor/server.sock"))
        #expect(volume.lowerBound < container.lowerBound && container.lowerBound < home.lowerBound)
    }

    /// A path with a quote, `$`, a backslash or a backquote isn't put in
    /// the command: the default runs instead.
    @Test func aPathShWouldReadMoreIntoIsNotRun() {
        for bad in ["/tmp/a'b.sock", "/tmp/a\"b.sock", "/tmp/$(rm).sock", "/tmp/a`b`.sock", "/tmp/a\\b.sock", "/tmp/a\nb.sock"] {
            let address = SSHAddress(target: SSHAddress.Hop(user: "logan", host: "mini"), socket: bad)
            #expect(address.attachCommand == SSHAddress.defaultAttachCommand, Comment(rawValue: bad))
        }
    }

    @Test func aBrokenOrEmptySocketIsNoAddress() {
        #expect(SSHAddress("ssh://logan@mini?socket=") == nil)
        #expect(SSHAddress("ssh://logan@mini?socket=%2") == nil)
    }

    @Test func anotherKeyIsPassedOverAsBefore() throws {
        let address = try #require(SSHAddress("ssh://logan@mini?later=1"))
        #expect(address.socket == nil)
        #expect(address.target.host == "mini")
    }
}
}
