// The GitHub App's JWT (GitHub's "Authenticating as a GitHub App"): RS256,
// RSASSA-PKCS1-v1_5 with SHA-256, signed with the App's key by swift-crypto's
// _CryptoExtras, which is BoringSSL's on the Mac and on Linux alike. Issued a
// minute ago (clocks drift), good for nine minutes from now (GitHub takes ten
// at most), the App's id its issuer. What it asks for is the App's own:
// its installations, and an installation's token (GitHubAppTokens).

import Foundation
import _CryptoExtras

enum GitHubAppJWT {
    /// The App's key, from its PEM: PKCS #1 (`BEGIN RSA PRIVATE KEY`) or
    /// PKCS #8 (`BEGIN PRIVATE KEY`), 2048 bits or more. Nil when it's
    /// neither (what was wrong never said: it would be the key's).
    static func key(pem: String) -> _RSA.Signing.PrivateKey? {
        guard pem.contains("-----BEGIN ") else { return nil }
        return try? _RSA.Signing.PrivateKey(pemRepresentation: pem)
    }

    /// The JWT for `appID` at `now`. An id of digits alone is a number, as
    /// GitHub gives it; another (a client id) a string.
    static func make(appID: String, key: _RSA.Signing.PrivateKey, now: Date) throws -> String {
        let seconds = Int(now.timeIntervalSince1970.rounded(.down))
        let issuer: Any
        if appID.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(appID) {
            issuer = number
        } else {
            issuer = appID
        }
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8)
        let claims = try JSONSerialization.data(withJSONObject: ["iat": seconds - 60, "exp": seconds + 9 * 60, "iss": issuer],
                                                options: [.sortedKeys])
        let input = base64URL(header) + "." + base64URL(claims)
        let signature = try key.signature(for: Data(input.utf8), padding: .insecurePKCS1v1_5)
        return input + "." + base64URL(signature.rawRepresentation)
    }

    /// base64url, unpadded.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
