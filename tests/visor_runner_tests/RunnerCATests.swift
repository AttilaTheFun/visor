// The GitHub proxy's authority (docs/github-proxy.md): made once and kept
// with the Runner's secrets, constrained to GitHub's names, its leaves only
// for GitHub's three hosts; a client that checks name constraints takes no
// leaf of it for another name.

import Crypto
import Foundation
@testable import VisorRunner
import X509
import XCTest

final class RunnerCATests: XCTestCase {
    func testItIsMadeOnceAndKept() throws {
        let secrets = MemorySecrets()
        let first = try RunnerCA.kept(in: secrets)
        let again = try RunnerCA.kept(in: secrets)
        XCTAssertEqual(first.certificate, again.certificate)
        XCTAssertTrue(try first.pem.hasPrefix("-----BEGIN CERTIFICATE-----"))
        XCTAssertNotNil(secrets.value("github-proxy ca key"), "the key is the Runner's secret")
    }

    func testItIsAnAuthorityConstrainedToGitHub() throws {
        let ca = try RunnerCA.kept(in: MemorySecrets())
        let constraints = try XCTUnwrap(ca.certificate.extensions.nameConstraints)
        XCTAssertEqual(constraints.permittedDNSDomains, ["github.com"])
        XCTAssertEqual(constraints.excludedIPRanges.count, 2, "no IPv4 or IPv6 address")
        XCTAssertEqual(ca.certificate.extensions[oid: .X509ExtensionID.nameConstraints]?.critical, true)
        XCTAssertEqual(try ca.certificate.extensions.basicConstraints, .isCertificateAuthority(maxPathLength: 0))
        XCTAssertThrowsError(try ca.leaf(for: "example.com")) { error in
            XCTAssertEqual(error as? RunnerCAError, .notGitHub("example.com"))
        }
    }

    func testAClientTakesItsLeavesForGitHubAlone() async throws {
        let ca = try RunnerCA.kept(in: MemorySecrets())
        for host in RunnerCA.hosts {
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
}
