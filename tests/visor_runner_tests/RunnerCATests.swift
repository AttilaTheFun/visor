// The GitHub proxy's authority (docs/github-proxy.md): made once and kept
// with the Runner's secrets, constrained to GitHub's names, its leaves only
// for GitHub's three hosts; a client that checks name constraints takes no
// leaf of it for another name.

import Crypto
import Foundation
@testable import VisorRunner
import X509
import Testing

@Suite final class RunnerCATests {
    @Test func testItIsMadeOnceAndKept() throws {
        let secrets = MemorySecrets()
        let first = try RunnerCA.kept(in: secrets)
        let again = try RunnerCA.kept(in: secrets)
        #expect(first.certificate == again.certificate)
        #expect(try first.pem.hasPrefix("-----BEGIN CERTIFICATE-----"))
        #expect(secrets.value("github-proxy ca key") != nil, "the key is the Runner's secret")
    }

    @Test func testItIsAnAuthorityConstrainedToGitHub() throws {
        let ca = try RunnerCA.kept(in: MemorySecrets())
        let constraints = try #require(try ca.certificate.extensions.nameConstraints)
        #expect(constraints.permittedDNSDomains == ["github.com"])
        #expect(constraints.excludedIPRanges.count == 2, "no IPv4 or IPv6 address")
        #expect((ca.certificate.extensions[oid: .X509ExtensionID.nameConstraints]?.critical) == true)
        #expect((try ca.certificate.extensions.basicConstraints) == .isCertificateAuthority(maxPathLength: 0))
        #expect(throws: RunnerCAError.notGitHub("example.com")) { try ca.leaf(for: "example.com") }
    }

    @Test func testAClientTakesItsLeavesForGitHubAlone() async throws {
        let ca = try RunnerCA.kept(in: MemorySecrets())
        for host in RunnerCA.hosts {
            let leaf = try ca.leaf(for: host).certificate
            var verifier = Verifier(rootCertificates: CertificateStore([ca.certificate])) {
                RFC5280Policy()
                ServerIdentityPolicy(serverHostname: host, serverIP: nil)
            }
            guard case .validCertificate = await verifier.validate(leaf: leaf, intermediates: CertificateStore()) else {
                Issue.record("\(host)'s leaf was not taken"); return
            }
        }
        // One it was made to sign for another name all the same: refused by
        // the constraint, not only by the proxy's own check.
        let stray = try ca.sign("example.com", now: Date()).certificate
        var verifier = Verifier(rootCertificates: CertificateStore([ca.certificate])) { RFC5280Policy() }
        guard case .couldNotValidate = await verifier.validate(leaf: stray, intermediates: CertificateStore()) else {
            Issue.record("a leaf for example.com was taken"); return
        }
    }
}
