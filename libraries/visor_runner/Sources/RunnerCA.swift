import Crypto
import Foundation
import SwiftASN1
import X509

/// The Runner's certificate authority for its GitHub proxy
/// (docs/github-proxy.md): the agents' systems trust it, and the proxy shows
/// a leaf of it for GitHub's hosts alone. It is constrained to GitHub's
/// names (RFC 5280's name constraints, critical): a client that checks them
/// takes no leaf of it for any other name, nor for any IP address. Made once
/// and kept with the Runner's secrets, its key never written anywhere else.
public struct RunnerCA: Sendable {
    /// The hosts the proxy opens. The constraint's subtree is `github.com`'s
    /// (its subdomains are GitHub's own), and the proxy mints leaves for
    /// these three alone.
    public static let hosts = ["github.com", "api.github.com", "uploads.github.com"]

    static let keySecret = "github-proxy ca key"
    static let certificateSecret = "github-proxy ca certificate"

    public let certificate: Certificate
    let key: P256.Signing.PrivateKey

    /// Its certificate, as the agents' systems are given it to trust.
    public var pem: String {
        get throws { try certificate.serializeAsPEM().pemString }
    }

    /// The Runner's, made the first time it is asked for.
    public static func kept(in secrets: RunnerSecrets, now: Date = Date()) throws -> RunnerCA {
        if let keyPEM = secrets.value(keySecret), let certificatePEM = secrets.value(certificateSecret) {
            return RunnerCA(certificate: try Certificate(pemEncoded: certificatePEM),
                            key: try P256.Signing.PrivateKey(pemRepresentation: keyPEM))
        }
        let made = try make(now: now)
        secrets.set(keySecret, made.key.pemRepresentation)
        secrets.set(certificateSecret, try made.pem)
        return made
    }

    /// A new one, good for ten years.
    static func make(now: Date) throws -> RunnerCA {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            OrganizationName("Visor")
            CommonName("Visor Runner GitHub proxy")
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(10 * 365 * 24 * 3600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                Critical(NameConstraints(permittedDNSDomains: ["github.com"],
                                         excludedIPRanges: [ASN1OctetString(contentBytes: [0, 0, 0, 0, 0, 0, 0, 0]),
                                                            ASN1OctetString(contentBytes: ArraySlice(repeating: 0, count: 32))]))
                SubjectKeyIdentifier(hash: .init(key.publicKey))
            },
            issuerPrivateKey: .init(key)
        )
        return RunnerCA(certificate: certificate, key: key)
    }

    /// A leaf for one of `hosts`, good for a week, and its key.
    public func leaf(for host: String, now: Date = Date()) throws -> (certificate: Certificate, key: P256.Signing.PrivateKey) {
        guard Self.hosts.contains(host) else { throw RunnerCAError.notGitHub(host) }
        return try sign(host, now: now)
    }

    /// A leaf for any name, unchecked: the tests' way to show a client refuses
    /// one for a name the constraint doesn't permit.
    func sign(_ host: String, now: Date) throws -> (certificate: Certificate, key: P256.Signing.PrivateKey) {
        let leafKey = P256.Signing.PrivateKey()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(7 * 24 * 3600),
            issuer: certificate.subject,
            subject: try DistinguishedName { CommonName(host) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(host)])
                AuthorityKeyIdentifier(keyIdentifier: try certificate.extensions.subjectKeyIdentifier?.keyIdentifier)
            },
            issuerPrivateKey: .init(key)
        )
        return (certificate, leafKey)
    }
}
