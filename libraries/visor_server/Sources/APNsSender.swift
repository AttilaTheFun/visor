import Foundation
import VisorProtocol

/// Pushes to Apple devices: a token signed with the owner's key (the
/// platform signs), and one request to APNs per device.
@MainActor
final class APNsSender {
    private var cached: (jwt: String, made: Date, keyID: String)?

    /// A signed token for APNs, made again every 40 minutes (APNs takes one
    /// for up to an hour).
    func jwt(for key: APNsKey, signing: any PushSigning) throws -> String {
        if let cached, cached.keyID == key.keyID, Date().timeIntervalSince(cached.made) < 40 * 60 { return cached.jwt }
        func part(_ object: [String: Any]) -> String {
            Self.base64URL((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
        }
        let body = part(["alg": "ES256", "kid": key.keyID]) + "." + part(["iss": key.teamID, "iat": Int(Date().timeIntervalSince1970)])
        let signature = try signing.sign(Data(body.utf8), with: key.pem)
        let jwt = body + "." + Self.base64URL(signature)
        cached = (jwt, Date(), key.keyID)
        return jwt
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The headers every push carries: where it goes, how it is signed.
    private nonisolated static func request(to device: PushDevice, jwt: String, collapse: String, type: String, priority: String,
                                            payload: [String: Any]) -> OutgoingRequest? {
        let host = device.environment == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return OutgoingRequest(url: "https://\(host)/3/device/\(device.token)", method: "POST",
                               headers: ["authorization": "bearer " + jwt, "apns-topic": device.topic, "apns-push-type": type,
                                         "apns-priority": priority, "apns-collapse-id": String(collapse.prefix(64))],
                               body: body, timeout: 20)
    }

    /// The whole request for one push: where it goes, how it is signed,
    /// what it says.
    nonisolated static func request(to device: PushDevice, jwt: String, title: String, body: String, collapse: String,
                                    data: [String: String]) -> OutgoingRequest? {
        // `content-available` wakes the app for the data too, so its
        // widget follows what the notification says.
        var payload: [String: Any] = ["aps": ["alert": ["title": title, "body": body], "sound": "default",
                                              "thread-id": data["session"] ?? "", "content-available": 1]]
        for (key, value) in data { payload[key] = value }
        return request(to: device, jwt: jwt, collapse: collapse, type: "alert", priority: "10", payload: payload)
    }

    /// The request for a silent push: nothing shown, only the data, sent
    /// as APNs asks a background push to be (its own type, priority 5).
    nonisolated static func statusRequest(to device: PushDevice, jwt: String, collapse: String, data: [String: String]) -> OutgoingRequest? {
        var payload: [String: Any] = ["aps": ["content-available": 1]]
        for (key, value) in data { payload[key] = value }
        return request(to: device, jwt: jwt, collapse: collapse, type: "background", priority: "5", payload: payload)
    }

    /// Sends one: the status APNs answered with (0 when unreachable), and
    /// the reason it gave for a refusal.
    func send(_ request: OutgoingRequest) async -> (status: Int, reason: String?) {
        guard let answer = try? await ServerPlatform.current.fetching.fetch(request) else { return (0, nil) }
        let reason = ((try? JSONSerialization.jsonObject(with: answer.body)) as? [String: Any])?["reason"] as? String
        return (answer.status, reason)
    }

    /// Whether APNs's answer says the device is not one to push to any
    /// more: the app was deleted (410), or the token is not one APNs knows
    /// for this app. A refusal of the request itself — the key, the topic,
    /// the payload — says nothing about the device.
    nonisolated static func forgets(status: Int, reason: String?) -> Bool {
        status == 410 || (status == 400 && ["BadDeviceToken", "DeviceTokenNotForTopic"].contains(reason ?? ""))
    }
}
