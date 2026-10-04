import Foundation

/// Signing with the owner's APNs key (a P-256 key in a .p8), which is what
/// a push to an Apple device is sent with. A system without it sends no
/// pushes.
public protocol PushSigning: Sendable {
    /// Whether `pem` is a key this can sign with.
    func accepts(_ pem: String) -> Bool
    /// The ES256 signature of `message` with the key in `pem`: r and s, 64
    /// bytes.
    func sign(_ message: Data, with pem: String) throws -> Data
}
