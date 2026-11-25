// agent-proxy's certificate authority for GitHub's hosts (MultiPass's
// RunnerCA, moved; Logan, 2026-11-14): the containers' systems trust it
// (its certificate, public, is the file they mount: agentProxy's
// `caCertificate`), and agent-proxy shows a leaf of it for GitHub's hosts
// alone. It is constrained to GitHub's names (RFC 5280's name constraints,
// critical): a client that checks them takes no leaf of it for any other
// name, nor for any IP address. Made once and kept as two of Visor's
// secrets (`agent-proxy/ca.pem`, `agent-proxy/ca-key.pem`: the keychain on
// a Mac), its key never written anywhere else. Visor's is made new, never
// Shireworks' moved: a private key doesn't move.
//
// A second authority, of the same make, is Anthropic's (`Scope.anthropic`):
// constrained to api.anthropic.com alone, its leaves for that host alone,
// kept as `agent-proxy/anthropic-ca.pem` and `-key.pem`. The Anthropic
// interceptor shows its leaves (docs/containers.md, "Claude's credential").
// Two, not one widened: a container that trusts GitHub's takes no leaf of it
// for any other name, and the same holds for Anthropic's.

import Crypto
import Foundation
import SwiftASN1
import X509

/// agent-proxy's authority for GitHub's three hosts (or, by its scope,
/// Anthropic's one): an immutable value, never changed once made
/// (swift-crypto 4's P256 key is Sendable).
public struct AgentProxyCA: Sendable {
    /// What an authority is for: its name, the one subtree its constraint
    /// permits, the hosts it makes leaves for, and its two Keychain items.
    public struct Scope: Equatable, Sendable {
        public let name: String
        public let domain: String
        public let hosts: [String]
        public let certificateAccount: String
        public let keyAccount: String

        /// GitHub's: the constraint's subtree is `github.com`'s (its
        /// subdomains are GitHub's own).
        public static let github = Scope(name: "Visor agent-proxy GitHub", domain: "github.com",
                                         hosts: ["github.com", "api.github.com", "uploads.github.com"],
                                         certificateAccount: "agent-proxy/ca.pem", keyAccount: "agent-proxy/ca-key.pem")
        /// Anthropic's API alone.
        public static let anthropic = Scope(name: "Visor agent-proxy Anthropic", domain: "api.anthropic.com", hosts: ["api.anthropic.com"],
                                            certificateAccount: "agent-proxy/anthropic-ca.pem",
                                            keyAccount: "agent-proxy/anthropic-ca-key.pem")
    }

    /// The hosts GitHub's makes leaves for.
    public static let hosts = Scope.github.hosts

    /// GitHub's Keychain items: the certificate (PEM) and its key (PEM).
    public static let certificateAccount = Scope.github.certificateAccount
    public static let keyAccount = Scope.github.keyAccount

    public let certificate: Certificate
    let key: P256.Signing.PrivateKey
    public let scope: Scope

    init(certificate: Certificate, key: P256.Signing.PrivateKey, scope: Scope = .github) {
        self.certificate = certificate
        self.key = key
        self.scope = scope
    }

    /// Its certificate, as the containers' systems are given it to trust.
    public var pem: String {
        get throws { try certificate.serializeAsPEM().pemString }
    }

    /// How long one is good for (NCH's review of #417: two years, not
    /// MultiPass's ten), and how near its end another is made in its place.
    static let lifetime: TimeInterval = 2 * 365 * 24 * 3600
    static let renewal: TimeInterval = 90 * 24 * 3600

    /// The one kept in `secrets`, made (and kept) the first time, and again
    /// once it has less than 90 days left: the certificate file the
    /// containers mount is then written anew (writeCertificate, at each
    /// start). Throws when the store can't be read: never taken for "none",
    /// which would make a second authority the containers don't trust.
    public static func kept(in secrets: any AgentProxySecrets, scope: Scope = .github, now: Date = Date()) throws -> AgentProxyCA {
        let keyPEM = try secrets.item(scope.keyAccount).map { String(decoding: $0, as: UTF8.self) }
        let certificatePEM = try secrets.item(scope.certificateAccount).map { String(decoding: $0, as: UTF8.self) }
        if let keyPEM, let certificatePEM {
            let kept = AgentProxyCA(certificate: try Certificate(pemEncoded: certificatePEM),
                                    key: try P256.Signing.PrivateKey(pemRepresentation: keyPEM), scope: scope)
            if kept.certificate.notValidAfter.timeIntervalSince(now) >= renewal { return kept }
        }
        let made = try make(now: now, scope: scope)
        // The key first: a certificate kept without its key would be made again.
        try secrets.setItem(scope.keyAccount, Data(made.key.pemRepresentation.utf8))
        try secrets.setItem(scope.certificateAccount, Data(try made.pem.utf8))
        return made
    }

    /// A new one, good for two years.
    static func make(now: Date, scope: Scope = .github) throws -> AgentProxyCA {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            OrganizationName("Visor")
            CommonName(scope.name)
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(lifetime),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                Critical(NameConstraints(permittedDNSDomains: [scope.domain],
                                         excludedIPRanges: [ASN1OctetString(contentBytes: [0, 0, 0, 0, 0, 0, 0, 0]),
                                                            ASN1OctetString(contentBytes: ArraySlice(repeating: 0, count: 32))]))
                SubjectKeyIdentifier(hash: .init(key.publicKey))
            },
            issuerPrivateKey: .init(key)
        )
        return AgentProxyCA(certificate: certificate, key: key, scope: scope)
    }

    /// A leaf for one of its scope's hosts, good for a week, and its key.
    public func leaf(for host: String, now: Date = Date()) throws -> (certificate: Certificate, key: P256.Signing.PrivateKey) {
        guard scope.hosts.contains(host) else {
            throw scope == .github ? AgentProxyCAError.notGitHub(host) : AgentProxyCAError.notItsHost(host)
        }
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

    /// Its certificate written where the containers mount it: `path`, mode
    /// 644 (public: a certificate, never its key), its folder made.
    public func writeCertificate(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(try pem.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }
}
