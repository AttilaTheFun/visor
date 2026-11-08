import Crypto
import Foundation
import SwiftASN1
import X509

/// The Runner's own TLS certificate for its side for clients
/// (docs/runner-accounts.md, "Reaching a Runner"): on the LAN and on
/// loopback, where no public name is to be had, the Runner shows this one,
/// self-signed, and a client pins it by its fingerprint the first time it
/// signs in, which the person checks against the Runner's
/// (`visor-runner-agent api certificate`). Its names are the Mac's, so a
/// client that checks names finds them; what is trusted is the fingerprint.
/// Made once and kept with the Runner's secrets, its key never written
/// anywhere else; made again when its names change or it nears its end
/// (a client then confirms the new one).
public struct RunnerIdentity: Sendable {
    static let keySecret = "runner tls key"
    static let certificateSecret = "runner tls certificate"
    /// How long one lasts, and how near its end it is made again.
    static let lifetime: TimeInterval = 397 * 24 * 3600
    static let renewal: TimeInterval = 30 * 24 * 3600

    public let certificate: Certificate
    let key: P256.Signing.PrivateKey

    public var pem: String {
        get throws { try certificate.serializeAsPEM().pemString }
    }

    /// The private key, as NIOSSL takes it.
    var keyPEM: String { key.pemRepresentation }

    /// The SHA-256 of the certificate (its DER), as `AB:CD:…`: what a client
    /// pins, and the person compares.
    public var fingerprint: String {
        get throws {
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            return SHA256.hash(data: serializer.serializedBytes).map { String(format: "%02X", $0) }.joined(separator: ":")
        }
    }

    /// The names it is for: always `localhost` and loopback's addresses, the
    /// Mac's own name, and those given (`api port --name`).
    public static func names(given: [String], host: String = ProcessInfo.processInfo.hostName) -> [String] {
        var names = ["localhost", "127.0.0.1", "::1"]
        for name in [host] + given where !name.isEmpty && !names.contains(name) { names.append(name) }
        return names
    }

    /// The one kept, or a new one when there is none, its names differ, or
    /// it ends within a month.
    public static func kept(in secrets: RunnerSecrets, names: [String], now: Date = Date()) throws -> RunnerIdentity {
        if let keyPEM = secrets.value(keySecret), let certificatePEM = secrets.value(certificateSecret),
           let certificate = try? Certificate(pemEncoded: certificatePEM),
           let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM),
           Self.names(of: certificate) == Set(names), certificate.notValidAfter.timeIntervalSince(now) > renewal {
            return RunnerIdentity(certificate: certificate, key: key)
        }
        let made = try make(names: names, now: now)
        secrets.set(keySecret, made.key.pemRepresentation)
        secrets.set(certificateSecret, try made.pem)
        return made
    }

    static func make(names: [String], now: Date) throws -> RunnerIdentity {
        let key = P256.Signing.PrivateKey()
        let subject = try DistinguishedName {
            OrganizationName("Visor")
            CommonName("Visor Runner")
        }
        let alternatives: [GeneralName] = names.map { name in
            address(name).map { .ipAddress(ASN1OctetString(contentBytes: ArraySlice($0))) } ?? .dnsName(name)
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(lifetime),
            issuer: subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames(alternatives)
            },
            issuerPrivateKey: .init(key)
        )
        return RunnerIdentity(certificate: certificate, key: key)
    }

    /// An address's bytes: IPv4's dotted four, or IPv6's loopback (`::1`),
    /// the one IPv6 address a Runner names. Nil for a host's name.
    static func address(_ name: String) -> [UInt8]? {
        if name == "::1" { return Array(repeating: 0, count: 15) + [1] }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    /// An address as `address` reads it.
    static func written(_ bytes: [UInt8]) -> String? {
        if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
        if bytes == Array(repeating: 0, count: 15) + [1] { return "::1" }
        return nil
    }

    /// The names a certificate is for, as `make` writes them.
    static func names(of certificate: Certificate) -> Set<String> {
        guard let alternatives = try? certificate.extensions.subjectAlternativeNames else { return [] }
        return Set(alternatives.compactMap { name -> String? in
            switch name {
            case .dnsName(let name): return name
            case .ipAddress(let bytes): return written(Array(bytes.bytes))
            default: return nil
            }
        })
    }
}
