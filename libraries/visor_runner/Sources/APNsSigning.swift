import Foundation

/// Signing with the owner's APNs key (a P-256 key in a .p8), as a push to an
/// Apple device is sent with: the system's (CryptoKit on a Mac). A Runner
/// with none proxies no pushes.
public protocol APNsSigning: Sendable {
    /// The ES256 signature of `message` with the key in `pem`: r and s, 64
    /// bytes.
    func sign(_ message: Data, with pem: String) throws -> Data
}
