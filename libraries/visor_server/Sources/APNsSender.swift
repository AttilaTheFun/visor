import CryptoKit
import Foundation
import VisorProtocol

@MainActor
final class APNsSender {
    private var cached: (jwt: String, made: Date, keyID: String)?

    /// A signed token for APNs, made again every 40 minutes (APNs takes one
    /// for up to an hour).
    func jwt(for key: APNsKey) throws -> String {
        if let cached, cached.keyID == key.keyID, Date().timeIntervalSince(cached.made) < 40 * 60 { return cached.jwt }
        let signer = try P256.Signing.PrivateKey(pemRepresentation: key.pem)
        func part(_ object: [String: Any]) -> String {
            Self.base64URL((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
        }
        let body = part(["alg": "ES256", "kid": key.keyID]) + "." + part(["iss": key.teamID, "iat": Int(Date().timeIntervalSince1970)])
        let signature = try signer.signature(for: Data(body.utf8)).rawRepresentation
        let jwt = body + "." + Self.base64URL(signature)
        cached = (jwt, Date(), key.keyID)
        return jwt
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The whole request for one push: where it goes, how it is signed,
    /// what it says.
    nonisolated static func request(to device: PushDevice, jwt: String, title: String, body: String, collapse: String,
                        data: [String: String]) -> URLRequest? {
        let host = device.environment == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(device.token)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("bearer " + jwt, forHTTPHeaderField: "authorization")
        request.setValue(device.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(String(collapse.prefix(64)), forHTTPHeaderField: "apns-collapse-id")
        var payload: [String: Any] = ["aps": ["alert": ["title": title, "body": body], "sound": "default",
                                              "thread-id": data["session"] ?? ""]]
        for (key, value) in data { payload[key] = value }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// Sends one: the status APNs answered with (0 when unreachable), and
    /// the reason it gave for a refusal.
    func send(_ request: URLRequest) async -> (status: Int, reason: String?) {
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (0, nil) }
        let reason = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["reason"] as? String
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, reason)
    }

    /// Whether APNs's answer says the device is not one to push to any
    /// more: the app was deleted (410), or the token is not one APNs knows
    /// for this app. A refusal of the request itself — the key, the topic,
    /// the payload — says nothing about the device.
    nonisolated static func forgets(status: Int, reason: String?) -> Bool {
        status == 410 || (status == 400 && ["BadDeviceToken", "DeviceTokenNotForTopic"].contains(reason ?? ""))
    }
}
