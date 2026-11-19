// agent-proxy's authority for GitHub's hosts (MultiPass's RunnerCATests,
// moved; Logan, 2026-11-14): made once and kept as two Keychain items (here a
// test's secrets), constrained to GitHub's names, its leaves only for
// GitHub's three hosts; a client that checks name constraints takes no leaf
// of it for another name. Its certificate is written for the containers to
// mount, mode 644, and its key never.

import Crypto
import Foundation
@testable import VisorAgentProxy
import X509
import XCTest

final class AgentProxyCATests: XCTestCase {
    func testItIsMadeOnceAndKeptAsItsTwoItems() throws {
        let secrets = MemoryProxySecrets()
        let first = try AgentProxyCA.kept(in: secrets)
        let again = try AgentProxyCA.kept(in: secrets)
        XCTAssertEqual(first.certificate, again.certificate)
        XCTAssertTrue(try first.pem.hasPrefix("-----BEGIN CERTIFICATE-----"))
        XCTAssertEqual(secrets.accounts, ["agent-proxy/ca-key.pem", "agent-proxy/ca.pem"])
        let key = String(decoding: try XCTUnwrap(try secrets.item("agent-proxy/ca-key.pem")), as: UTF8.self)
        XCTAssertTrue(key.contains("PRIVATE KEY"), "the key is the Keychain's item")
    }

    /// NCH's review of #417: two years, and made again (its items and the
    /// certificate the containers mount) once it has less than 90 days left.
    func testItIsGoodForTwoYearsAndMadeAgainNearItsEnd() throws {
        let secrets = MemoryProxySecrets()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try AgentProxyCA.kept(in: secrets, now: start)
        XCTAssertEqual(first.certificate.notValidAfter.timeIntervalSince(start), 2 * 365 * 24 * 3600, accuracy: 2)
        let later = try AgentProxyCA.kept(in: secrets, now: start.addingTimeInterval(600 * 24 * 3600))
        XCTAssertEqual(later.certificate, first.certificate, "more than 90 days left: kept")
        let near = try AgentProxyCA.kept(in: secrets, now: start.addingTimeInterval(650 * 24 * 3600))
        XCTAssertNotEqual(near.certificate, first.certificate, "less than 90 days left: made again")
        XCTAssertEqual(try AgentProxyCA.kept(in: secrets, now: start.addingTimeInterval(651 * 24 * 3600)).certificate, near.certificate, "and kept")
    }

    /// A store that doesn't answer is never taken for an empty one: no
    /// second authority is made over the first.
    func testAStoreThatDoesntAnswerMakesNone() {
        struct Unanswering: AgentProxySecrets {
            struct Refused: Error {}
            func item(_ account: String) throws -> Data? { throw Refused() }
            func setItem(_ account: String, _ data: Data) throws { XCTFail("nothing is made") }
        }
        XCTAssertThrowsError(try AgentProxyCA.kept(in: Unanswering()))
    }

    func testItIsAnAuthorityConstrainedToGitHub() throws {
        let ca = try AgentProxyCA.kept(in: MemoryProxySecrets())
        let constraints = try XCTUnwrap(ca.certificate.extensions.nameConstraints)
        XCTAssertEqual(constraints.permittedDNSDomains, ["github.com"])
        XCTAssertEqual(constraints.excludedIPRanges.count, 2, "no IPv4 or IPv6 address")
        XCTAssertEqual(ca.certificate.extensions[oid: .X509ExtensionID.nameConstraints]?.critical, true)
        XCTAssertEqual(try ca.certificate.extensions.basicConstraints, .isCertificateAuthority(maxPathLength: 0))
        XCTAssertThrowsError(try ca.leaf(for: "example.com")) { error in
            XCTAssertEqual(error as? AgentProxyCAError, .notGitHub("example.com"))
        }
    }

    func testAClientTakesItsLeavesForGitHubAlone() async throws {
        let ca = try AgentProxyCA.kept(in: MemoryProxySecrets())
        for host in AgentProxyCA.hosts {
            let leaf = try ca.leaf(for: host).certificate
            var verifier = Verifier(rootCertificates: CertificateStore([ca.certificate])) {
                RFC5280Policy()
                ServerIdentityPolicy(serverHostname: host, serverIP: nil)
            }
            guard case .validCertificate = await verifier.validate(leaf: leaf, intermediates: CertificateStore()) else {
                return XCTFail("\(host)'s leaf was not taken")
            }
        }
        // One it was made to sign for another name all the same: refused by
        // the constraint, not only by the proxy's own check.
        let stray = try ca.sign("example.com", now: Date()).certificate
        var verifier = Verifier(rootCertificates: CertificateStore([ca.certificate])) { RFC5280Policy() }
        guard case .couldNotValidate = await verifier.validate(leaf: stray, intermediates: CertificateStore()) else {
            return XCTFail("a leaf for example.com was taken")
        }
    }

    /// The certificate the containers mount: public, mode 644, its folder
    /// made, and nothing of the key in it.
    func testItsCertificateIsWrittenForTheContainersAndItsKeyIsnt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-proxy-ca-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("agent-proxy/ca.pem").path
        let ca = try AgentProxyCA.kept(in: MemoryProxySecrets())
        try ca.writeCertificate(to: path)
        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(written, try ca.pem)
        XCTAssertFalse(written.contains("PRIVATE KEY"))
        let mode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o644)
    }
}
