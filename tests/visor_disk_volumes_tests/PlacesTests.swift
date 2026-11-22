// The Visor family's sockets in the app group's container (VisorPlaces):
// `r/` in it, short names, and every path under the 104 bytes a Mac allows
// a socket's; none there without the container, or when a home is too long
// for them to fit.

import DiskVolumes
import Foundation
import Testing

@Suite struct PlacesTests {
    /// The container a Mac gives the group for `user`.
    private func container(_ user: String) -> URL {
        URL(fileURLWithPath: "/Users/\(user)/Library/Group Containers/\(VisorPlaces.appGroup)", isDirectory: true)
    }

    private func everySocket(_ places: VisorPlaces) -> [String?] {
        [places.serverSocket, places.relaySocket, places.driverSocket, places.hostSocket(0), places.hostSocket(.max)]
    }

    @Test func theSocketsAreInRInTheGroupsContainer() {
        let places = VisorPlaces.locate { $0 == VisorPlaces.appGroup ? container("logan") : nil }
        let root = "/Users/logan/Library/Group Containers/group.com.LoganShire.Visor/r/"
        #expect(places.socketFolder?.path == String(root.dropLast()))
        #expect(places.serverSocket == root + "server.sock")
        #expect(places.relaySocket == root + "relay.sock")
        #expect(places.driverSocket == root + "driver.sock")
        #expect(places.hostSocket(0x00c0_ffee) == root + "h-00c0ffee.sock")
    }

    @Test func hostSocketsHaveShortNames() {
        #expect(VisorPlaces.hostSocketName(0) == "h-00000000.sock")
        #expect(VisorPlaces.hostSocketName(.max) == "h-ffffffff.sock")
        #expect(VisorPlaces.hostSocketName(0xabc) == "h-00000abc.sock")
    }

    /// Every path under 104 bytes, for a user's name as long as fits.
    @Test func everyPathIsUnder104Bytes() throws {
        for user in ["l", "logan", "logan.shire", String(repeating: "u", count: 26)] {
            let places = VisorPlaces(groupContainer: container(user))
            for socket in everySocket(places) {
                let path = try #require(socket, Comment(rawValue: user))
                #expect(path.utf8.count < VisorPlaces.socketPathLimit, Comment(rawValue: path))
                #expect(VisorPlaces.fits(path))
            }
        }
    }

    /// A home too long for them: none there (the sockets stay where they
    /// were), rather than one that can't be listened on.
    @Test func aHomeTooLongHasNone() {
        let places = VisorPlaces(groupContainer: container(String(repeating: "u", count: 27)))
        #expect(places.socketFolder == nil)
        #expect(everySocket(places).allSatisfy { $0 == nil })
    }

    @Test func withoutTheContainerThereAreNone() {
        let places = VisorPlaces.locate { _ in nil }
        #expect(places.groupContainer == nil)
        #expect(places.socketFolder == nil)
        #expect(everySocket(places).allSatisfy { $0 == nil })
    }

    @Test func theLimitIsSunPaths() {
        #expect(VisorPlaces.fits(String(repeating: "a", count: 103)))
        #expect(!VisorPlaces.fits(String(repeating: "a", count: 104)))
    }
}
