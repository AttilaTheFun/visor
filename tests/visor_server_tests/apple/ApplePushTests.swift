// Pushes signed with a real APNs key, which takes CryptoKit (a Mac's
// platform): the token APNs is given, and the key set over the REST side.

import CryptoKit
import Foundation
import VisorProtocol
@testable import VisorServer
import VisorServerApple
import XCTest

@MainActor
final class ApplePushSigningTests: ServerTestCase {
    func testTheSigningTokenVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let jwt = try APNsSender().jwt(for: APNsKey(pem: key.pemRepresentation, keyID: "ABCDEFGHIJ", teamID: "TEAMTEAM12"),
                                       signing: CryptoKitPushSigning())
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func decode(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)!
        }
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: String]
        XCTAssertEqual(header, ["alg": "ES256", "kid": "ABCDEFGHIJ"])
    }
}

/// The APNs key can be set over the REST side by whoever is let in, and
/// is never answered back.
@MainActor
final class PushKeyRouteTests: ServerTestCase {
    func testTheKeyIsSetOverREST() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-pushkey-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        let server = VisorServer(port: 7974)
        server.password = "pw"
        defer { server.stop() }
        func post(_ path: String, _ body: String, bearer: String = "pw") -> HTTPResponse {
            server.route(HTTPRequest(method: "POST", path: path, headers: ["authorization": "Bearer " + bearer], body: body))
        }
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let body = String(decoding: try! JSONSerialization.data(withJSONObject: ["key": pem, "keyID": "ABCDEFGHIJ", "teamID": "TEAMTEAM12"]), as: UTF8.self)
        XCTAssertEqual(post("/api/push/key", body, bearer: "wrong").status, 401)
        XCTAssertEqual(post("/api/push/key", #"{"key":"nonsense","keyID":"ABCDEFGHIJ","teamID":"TEAMTEAM12"}"#).status, 400)
        let set = post("/api/push/key", body)
        XCTAssertEqual(set.status, 200)
        XCTAssertFalse(set.body.contains("PRIVATE KEY"), "the key is not answered back")
        XCTAssertEqual(server.apnsKey.keyID, "ABCDEFGHIJ")
        XCTAssertTrue(server.apnsKey.configured)
        XCTAssertEqual(post("/api/push/test", "").status, 400, "no device yet")
    }
}
