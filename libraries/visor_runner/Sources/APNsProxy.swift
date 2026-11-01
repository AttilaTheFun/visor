import Foundation
import Synchronization

/// The Runner's push proxy (docs/co-tenancy.md): a Visor server with no
/// APNs key of its own (one in a container) sends each push here as it
/// would send it to APNs, unsigned — `POST /apns/<APNs's host>/3/device/
/// <device token>`, with its token for the Runner (`MCPProxy.tokenHeader`) —
/// and it goes on to APNs signed with the key the Runner alone keeps.
/// APNs's answer comes back as it came, so the server hears of a device
/// that is gone. Nothing but a push to APNs goes through.
public final class APNsProxy: Sendable {
    /// APNs, and its sandbox: the only places a push goes.
    public static let hosts: Set<String> = ["api.push.apple.com", "api.sandbox.push.apple.com"]
    /// APNs's own headers, passed on; no other is.
    static let passed: Set<String> = ["apns-topic", "apns-push-type", "apns-priority", "apns-collapse-id", "apns-expiration", "apns-id"]
    /// Where the key is kept with the Runner's secrets: the .p8's text, its
    /// id and the team's.
    public static let keySecret = "apns key"
    public static let keyIDSecret = "apns keyID"
    public static let teamIDSecret = "apns teamID"

    /// A push as it goes on to APNs.
    public struct Outgoing: Equatable, Sendable {
        public var url: String
        public var headers: [String: String]
        public var body: Data
    }

    /// What came back: APNs's status (0 when it couldn't be reached) and
    /// body (its reason, for a refusal).
    public struct Answer: Equatable, Sendable {
        public var status: Int
        public var body: Data

        public init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }
    }

    private let secrets: RunnerSecrets
    private let signing: any APNsSigning
    private let send: @Sendable (Outgoing) -> Answer
    /// The signed token, made again every 40 minutes (APNs takes one for up
    /// to an hour, and refuses one made again more often than every 20).
    private let token = Mutex<(jwt: String, made: Date, keyID: String)?>(nil)

    /// `send` takes a push to APNs and waits for its answer.
    public init(secrets: RunnerSecrets, signing: any APNsSigning, send: @escaping @Sendable (Outgoing) -> Answer) {
        self.secrets = secrets
        self.signing = signing
        self.send = send
    }

    /// Whether a key is kept to sign with.
    public var hasKey: Bool { key != nil }

    private var key: (pem: String, keyID: String, teamID: String)? {
        guard let pem = secrets.value(Self.keySecret), !pem.isEmpty, let keyID = secrets.value(Self.keyIDSecret),
              let teamID = secrets.value(Self.teamIDSecret) else { return nil }
        return (pem, keyID, teamID)
    }

    /// The answer to a request for `/apns/…` (`path`, from the proxy's
    /// listener) that carried a server's token.
    func answer(method: String, path: String, headers: [(name: String, value: String)], body: Data) -> Answer {
        guard method == "POST" else { return Self.refusal(405, "MethodNotAllowed") }
        guard let push = Self.push(path: path, headers: headers, body: body) else { return Self.refusal(400, "NotAPush") }
        guard let key else { return Self.refusal(503, "NoKey") }
        let jwt: String
        do {
            jwt = try signed(key)
        } catch {
            return Self.refusal(503, "KeyDoesNotSign")
        }
        var signed = push
        signed.headers["authorization"] = "bearer " + jwt
        return send(signed)
    }

    /// The push a request asks for, APNs's address and headers only; nil for
    /// anything but a push to a device at APNs.
    static func push(path: String, headers: [(name: String, value: String)], body: Data) -> Outgoing? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // "", "apns", host, "3", "device", token
        guard parts.count == 6, parts[0].isEmpty, parts[1] == "apns", hosts.contains(String(parts[2])), parts[3] == "3", parts[4] == "device",
              !parts[5].isEmpty, parts[5].allSatisfy(\.isHexDigit) else { return nil }
        var kept: [String: String] = [:]
        for header in headers where passed.contains(header.name.lowercased()) { kept[header.name.lowercased()] = header.value }
        return Outgoing(url: "https://\(parts[2])/3/device/\(parts[5])", headers: kept, body: body)
    }

    /// The token APNs takes, signed with the key (again when it is 40
    /// minutes old, or the key changed).
    func signed(_ key: (pem: String, keyID: String, teamID: String), now: Date = Date()) throws -> String {
        try token.withLock { cached in
            if let cached, cached.keyID == key.keyID, now.timeIntervalSince(cached.made) < 40 * 60 { return cached.jwt }
            func part(_ object: [String: Any]) -> String {
                Self.base64URL((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
            }
            let body = part(["alg": "ES256", "kid": key.keyID]) + "." + part(["iss": key.teamID, "iat": Int(now.timeIntervalSince1970)])
            let jwt = body + "." + Self.base64URL(try signing.sign(Data(body.utf8), with: key.pem))
            cached = (jwt, now, key.keyID)
            return jwt
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A refusal of the proxy's own, shaped as APNs's are (`reason`).
    static func refusal(_ status: Int, _ reason: String) -> Answer {
        Answer(status: status, body: Data(#"{"reason":"\#(reason)"}"#.utf8))
    }
}
