/// A server's connection codes, as it makes them: the one its QR code shows
/// (its first path first), and one leading with each kind of path it has
/// (nil for a kind it has none of). The menu bar app and a client's
/// computer settings show the same, so a code read off either adds the
/// computer the same way.
public struct ConnectionCodes: Codable, Equatable, Sendable {
    public var qr: String
    public var http: String?
    public var https: String?
    public var ssh: String?

    public init(qr: String, http: String? = nil, https: String? = nil, ssh: String? = nil) {
        self.qr = qr
        self.http = http
        self.https = https
        self.ssh = ssh
    }

    /// The QR code's link: opens Visor on the device that scans it, and
    /// adds the computer.
    public var link: String { "\(ConnectionCode.scheme)://connect?code=\(qr)" }

    /// The code leading with a path of `kind`, nil when there is none.
    public func code(for kind: ConnectionPath) -> String? {
        switch kind {
        case .http: http
        case .https: https
        case .ssh: ssh
        }
    }

    /// The codes of `code`: itself for the QR code, and each kind of path
    /// first.
    public init(_ code: ConnectionCode) {
        self.init(qr: code.encoded, http: code.preferring(.http)?.encoded, https: code.preferring(.https)?.encoded,
                  ssh: code.preferring(.ssh)?.encoded)
    }
}
