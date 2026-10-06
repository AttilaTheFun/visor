// A server's address: a bare name, or any URL a port, a proxy or a
// tunnel gives, each turned into the root, the socket and the API.

import VisorProtocol
import XCTest

final class ServerAddressTests: XCTestCase {
    func testABareNameIsHTTPSAtTheRoot() throws {
        let mac = try XCTUnwrap(ServerAddress("  mac.tail1234.ts.net \n"))
        XCTAssertEqual(mac.root, "https://mac.tail1234.ts.net")
        XCTAssertEqual(mac.socket, "wss://mac.tail1234.ts.net/")
        XCTAssertEqual(mac.api, "https://mac.tail1234.ts.net/api")
        XCTAssertTrue(mac.isBareName)
        XCTAssertEqual(mac.display, "mac.tail1234.ts.net")
    }

    func testAURLKeepsItsSchemePortAndMount() throws {
        let proxied = try XCTUnwrap(ServerAddress("https://proxy.example.com/visor/"))
        XCTAssertEqual(proxied.root, "https://proxy.example.com/visor")
        XCTAssertEqual(proxied.socket, "wss://proxy.example.com/visor/")
        XCTAssertEqual(proxied.api, "https://proxy.example.com/visor/api")
        XCTAssertFalse(proxied.isBareName)
        XCTAssertEqual(proxied.display, "https://proxy.example.com/visor")
        let plain = try XCTUnwrap(ServerAddress("http://10.0.0.5:7434"))
        XCTAssertEqual(plain.socket, "ws://10.0.0.5:7434/")
        XCTAssertEqual(plain.api, "http://10.0.0.5:7434/api")
        XCTAssertFalse(plain.isBareName)
        // The socket's own form is taken too.
        XCTAssertEqual(ServerAddress("wss://mac.example/visor")?.root, "https://mac.example/visor")
        XCTAssertNil(ServerAddress("  "))
    }
}
