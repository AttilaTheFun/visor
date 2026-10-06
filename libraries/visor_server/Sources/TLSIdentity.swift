import Foundation

/// A certificate and its key for the server to present: a PKCS#12 file
/// and the password it was exported with.
public struct TLSIdentity: Sendable, Equatable {
    public var pkcs12: Data
    public var password: String

    public init(pkcs12: Data, password: String) {
        self.pkcs12 = pkcs12
        self.password = password
    }
}
