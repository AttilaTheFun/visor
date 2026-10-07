// A host key written as OpenSSH writes it: what NIOSSH parses back is
// the same key, for every kind of key NIOSSH has.

import Crypto
import NIOSSH
@testable import VisorSSH
import XCTest

final class OpenSSHLineTests: XCTestCase {
    func testTheLineParsesBackToTheSameKey() throws {
        let keys: [NIOSSHPrivateKey] = [
            NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()),
            NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey()),
            NIOSSHPrivateKey(p384Key: P384.Signing.PrivateKey()),
            NIOSSHPrivateKey(p521Key: P521.Signing.PrivateKey()),
        ]
        for key in keys {
            let line = key.publicKey.openSSHLine
            XCTAssertFalse(line.isEmpty)
            XCTAssertEqual(try NIOSSHPublicKey(openSSHPublicKey: line), key.publicKey, line.prefix(30) + "…")
        }
        // The device's line, as the services write it, parses the same way.
        let raw = SSHConnector.newPrivateKey()
        let device = try XCTUnwrap(SSHConnector.publicKeyLine(forPrivateKey: raw, comment: "visor"))
        XCTAssertTrue(device.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"), device)
        XCTAssertTrue(device.hasSuffix(" visor"))
        XCTAssertNoThrow(try NIOSSHPublicKey(openSSHPublicKey: String(device.dropLast(6))))
    }
}
