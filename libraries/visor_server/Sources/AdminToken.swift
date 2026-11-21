// The admin token: an opaque random secret (32 bytes, as 64 hex digits),
// not a JWT, and an additional REST credential beside the client password
// and the trusted socket (`Authorization: Bearer <admin token>`). Only its
// SHA-256 is held, and there is one at a time: rotating replaces it, and
// the one before stops working at once. Compared in constant time.
//
// Where its hash lives is the binary's to say:
// - Kept (the menu bar app): with the server's secrets (the keychain);
//   and, where the binary asks (`keepingToken`: Visor.app, 0.65), the token
//   itself beside it, in the data-protection keychain under the app's own
//   group, for `Visor admin-token` to print to a script (so no .zshrc
//   holds it). Made only when there is none (`visor-server admin-token`, Settings ›
//   Create Admin Token…), rotated only by presenting it (`POST
//   /api/admin-token/rotate`), reset without it only from the menu bar
//   (`reset`, in the app's own process).
// - Given at launch (the command-line server): from VISOR_ADMIN_TOKEN or
//   `--admin-token-file`, its hash held in memory alone and never written.
//   Launched with none, there is none: admin REST takes only the password
//   and the trusted socket. A new one is a relaunch with it.

import Crypto
import Foundation

@MainActor
package final class AdminToken {
    /// Where its hash lives.
    package enum Holding: Equatable, Sendable {
        /// With the server's secrets: made, rotated and reset here.
        case kept
        /// Given at launch, in memory alone.
        case givenAtLaunch
    }

    /// Why the token couldn't be made or rotated.
    package enum Refusal: Error, Equatable, Sendable {
        /// There is one already: only rotating (with it) replaces it.
        case exists
        /// The current one wasn't shown.
        case notPresented
        /// It is given at launch here: a relaunch with a new one replaces it.
        case givenAtLaunch

        package var message: String {
            switch self {
            case .exists: "There is an admin token already: rotate it by presenting it (POST /api/admin-token/rotate, "
                + "or visor-server admin-token rotate with $VISOR_ADMIN_TOKEN), or reset it from Visor Server's menu."
            case .notPresented: "Rotating the admin token takes the current one: Authorization: Bearer <admin token>."
            case .givenAtLaunch: "This server's admin token is given at launch (VISOR_ADMIN_TOKEN or --admin-token-file): "
                + "relaunch it with a new one (visor-server admin-token generate makes one)."
            }
        }
    }

    /// Where its hash is kept among the server's secrets.
    package static let secretKey = "adminTokenHash"
    /// Where the token itself is kept, when it is (`keepingToken`).
    package static let tokenKey = "adminToken"

    package let holding: Holding
    private let secrets: (any SecretStore)?
    private var hash: [UInt8]?
    /// Whether the token itself is kept beside its hash (`tokenKey`).
    private let keepsToken: Bool

    /// Kept with `secrets`; `keepingToken`, the token itself too.
    package init(keptIn secrets: any SecretStore, keepingToken: Bool = false) {
        holding = .kept
        self.secrets = secrets
        keepsToken = keepingToken
        hash = secrets.get(Self.secretKey).flatMap(Self.bytes(hex:))
    }

    /// Given at launch (`token`, or none), its hash in memory alone.
    package init(givenAtLaunch token: String?) {
        holding = .givenAtLaunch
        secrets = nil
        keepsToken = false
        hash = token.flatMap { $0.isEmpty ? nil : Self.digest($0) }
    }

    /// Whether there is one.
    package var exists: Bool { hash != nil }

    /// Whether `bearer` is it.
    package func admits(_ bearer: String?) -> Bool {
        guard let hash, let bearer, !bearer.isEmpty else { return false }
        let shown = Self.digest(bearer)
        var difference: UInt8 = 0
        for index in hash.indices { difference |= hash[index] ^ shown[index] }
        return difference == 0
    }

    /// The first token, shown this once: only where it is kept, and only
    /// when there is none.
    package func create() -> Result<String, Refusal> {
        guard holding == .kept else { return .failure(.givenAtLaunch) }
        guard hash == nil else { return .failure(.exists) }
        return .success(replace())
    }

    /// A new token in place of `current`, which must be the one there is:
    /// shown this once; the old one stops working now.
    package func rotate(presenting current: String?) -> Result<String, Refusal> {
        guard holding == .kept else { return .failure(.givenAtLaunch) }
        guard admits(current) else { return .failure(.notPresented) }
        return .success(replace())
    }

    /// A new token without the current one: the menu bar's Reset Admin
    /// Token…, in the app's own process, and nothing else. Nil where it is
    /// given at launch.
    package func reset() -> String? {
        guard holding == .kept else { return nil }
        return replace()
    }

    private func replace() -> String {
        let token = SecretToken.mint()
        let digest = Self.digest(token)
        hash = digest
        secrets?.set(Self.secretKey, Self.hex(digest))
        if keepsToken { secrets?.set(Self.tokenKey, token) }
        return token
    }

    /// A fresh token, stored nowhere: `visor-server admin-token generate`.
    package nonisolated static func generate() -> String {
        SecretToken.mint()
    }

    nonisolated static func digest(_ token: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(token.utf8)))
    }

    nonisolated static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func bytes(hex: String) -> [UInt8]? {
        guard hex.count == 64 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
