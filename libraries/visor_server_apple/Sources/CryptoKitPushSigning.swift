import CryptoKit
import Foundation
import VisorServer

/// APNs keys read and used with CryptoKit.
public struct CryptoKitPushSigning: PushSigning {
    public init() {}

    public func accepts(_ pem: String) -> Bool {
        (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil
    }

    public func sign(_ message: Data, with pem: String) throws -> Data {
        try P256.Signing.PrivateKey(pemRepresentation: pem).signature(for: message).rawRepresentation
    }
}
