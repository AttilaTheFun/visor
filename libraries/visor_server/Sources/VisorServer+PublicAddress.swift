// Where clients are told to reach this server. The exposure (Tailscale
// Serve) says its own name once it is up; a server fronted some other way
// — a reverse proxy, a tunnel — is told the URL that road gives, and the
// connection code carries that instead. Kept in the data directory with
// the sessions, so it is there from the first launch after it is set.

import Foundation
import VisorProtocol

extension VisorServer {
    static var publicAddressURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("public-address") }

    /// The address clients take: the one set by hand, else the exposure's.
    public var reachableAddress: String? {
        let set = publicAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return set.isEmpty ? address : set
    }

    /// Whether the server is reached some other way than the exposure's
    /// front: an address set by hand, which the exposure then need not
    /// provide (its absence is not an error).
    public var frontedElsewhere: Bool { !publicAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func keptPublicAddress() -> String {
        (try? String(contentsOf: publicAddressURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func keepPublicAddress() {
        let value = publicAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { try? FileManager.default.removeItem(at: Self.publicAddressURL) }
        else { try? value.write(to: Self.publicAddressURL, atomically: true, encoding: .utf8) }
    }
}
