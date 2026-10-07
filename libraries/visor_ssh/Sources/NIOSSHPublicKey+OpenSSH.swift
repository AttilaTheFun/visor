import Crypto
import Foundation
import NIOSSH

extension NIOSSHPublicKey {
    /// The key as an `authorized_keys` or `known_hosts` entry: its type
    /// and its wire form in base64, as OpenSSH writes it. NIOSSH parses
    /// such lines but writes none, and keeps the key's bytes to itself;
    /// they are read here through reflection, for the key types NIOSSH
    /// has (Ed25519, and ECDSA on the three NIST curves). A key of a
    /// kind it does not know gives "".
    var openSSHLine: String {
        guard let backing = Mirror(reflecting: self).children.first(where: { $0.label == "backingKey" })?.value,
              let key = Mirror(reflecting: backing).children.first?.value else { return "" }
        if let ed = key as? Curve25519.Signing.PublicKey {
            return Self.line("ssh-ed25519", [Data(ed.rawRepresentation)])
        }
        if let p256 = key as? P256.Signing.PublicKey {
            return Self.line("ecdsa-sha2-nistp256", [Data("nistp256".utf8), p256.x963Representation])
        }
        if let p384 = key as? P384.Signing.PublicKey {
            return Self.line("ecdsa-sha2-nistp384", [Data("nistp384".utf8), p384.x963Representation])
        }
        if let p521 = key as? P521.Signing.PublicKey {
            return Self.line("ecdsa-sha2-nistp521", [Data("nistp521".utf8), p521.x963Representation])
        }
        return ""
    }

    /// The SSH wire form: each field a 32-bit big-endian length and its
    /// bytes, the type's name first.
    private static func line(_ type: String, _ fields: [Data]) -> String {
        var wire = Data()
        for field in [Data(type.utf8)] + fields {
            let count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: count) { wire.append(contentsOf: $0) }
            wire.append(field)
        }
        return type + " " + wire.base64EncodedString()
    }
}
