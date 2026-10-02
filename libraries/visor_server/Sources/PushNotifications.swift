// Push notifications, sent by this server to the devices whose apps gave
// it their tokens: a turn finished, a goal achieved (and how long it took),
// an agent waiting for approval or stopped by an error — so a phone hears
// of it with the app closed. APNs is reached directly, signed with the
// owner's APNs key (Settings → Push Notifications), kept in the keychain.
//
// What a push says is the session's name and a fixed phrase; its data
// names the computer and the session. Nothing the agent or the user said
// goes to Apple.

import CryptoKit
import Foundation
import VisorProtocol

/// A device that asked for pushes.
struct PushDevice: Codable, Equatable {
    let token: String
    let platform: String
    let environment: String
    let topic: String
    var registered: Double
}

/// What a session last looked like, for telling what changed.
struct PushState: Equatable {
    var busy = false
    var waiting = false
    var failed = false
    var goal: String?
    var goalSince: Double?
}

/// The owner's APNs key: its PEM, its id, the team's.
struct APNsKey {
    let pem: String
    let keyID: String
    let teamID: String
}

final class APNsSender: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (jwt: String, made: Date, keyID: String)?

    /// A signed token for APNs, made again every 40 minutes (APNs takes one
    /// for up to an hour).
    func jwt(for key: APNsKey) throws -> String {
        lock.lock(); defer { lock.unlock() }
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

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The whole request for one push: where it goes, how it is signed,
    /// what it says.
    static func request(to device: PushDevice, jwt: String, title: String, body: String, collapse: String,
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

    /// Sends one; the status APNs answered with (0 when unreachable).
    func send(_ request: URLRequest) async -> Int {
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return 0 }
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

extension VisorServer {
    // MARK: Devices

    static var pushDevicesURL: URL { storeURL.deletingLastPathComponent().appendingPathComponent("push.json") }

    static func keptPushDevices() -> [PushDevice] {
        guard let data = try? Data(contentsOf: pushDevicesURL) else { return [] }
        return (try? JSONDecoder().decode([PushDevice].self, from: data)) ?? []
    }

    private func keepPushDevices() {
        if let data = try? JSONEncoder().encode(pushDevices) { try? data.write(to: Self.pushDevicesURL, options: .atomic) }
    }

    /// A device's token, kept (again, when it registers again). Any
    /// platform may register; an Apple device's token is hex and names its
    /// app, which APNs needs. Only Apple devices are sent pushes so far.
    func registerPush(_ envelope: Envelope) -> Bool {
        guard let token = envelope.deviceToken, !token.isEmpty else { return false }
        let platform = envelope.platform ?? ""
        let topic = envelope.pushTopic ?? ""
        if Self.apnsPlatforms.contains(platform), !token.allSatisfy(\.isHexDigit) || topic.isEmpty { return false }
        let device = PushDevice(token: token, platform: platform, environment: envelope.pushEnvironment ?? "",
                                topic: topic, registered: Date().timeIntervalSince1970)
        pushDevices.removeAll { $0.token == token }
        pushDevices.append(device)
        keepPushDevices()
        return true
    }

    // MARK: The key

    /// The APNs key as set in Settings, if all of it is.
    public var apnsKey: (keyID: String, teamID: String, configured: Bool) {
        let key = Self.secrets.get("apns.key") ?? ""
        return (Self.secrets.get("apns.keyID") ?? "", Self.secrets.get("apns.teamID") ?? "", !key.isEmpty)
    }

    /// Keeps the APNs key: the .p8's contents, its id and the team's. Nil
    /// when it is usable; otherwise why not.
    public func setAPNsKey(pem: String, keyID: String, teamID: String) -> String? {
        let pem = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil else { return "That is not an APNs key (.p8)." }
        guard keyID.count == 10, teamID.count == 10 else { return "The key id and the team id are ten characters each." }
        Self.secrets.set("apns.key", pem)
        Self.secrets.set("apns.keyID", keyID)
        Self.secrets.set("apns.teamID", teamID)
        objectWillChange.send()
        return nil
    }

    private var storedAPNsKey: APNsKey? {
        guard let pem = Self.secrets.get("apns.key"), !pem.isEmpty,
              let keyID = Self.secrets.get("apns.keyID"), let teamID = Self.secrets.get("apns.teamID") else { return nil }
        return APNsKey(pem: pem, keyID: keyID, teamID: teamID)
    }

    // MARK: What is said

    /// The address clients know this computer by, which a push's data names.
    var pushComputer: String { address ?? hostName }

    /// Pushes for what changed since the sessions were last looked at.
    func notifyPushes() {
        var next: [String: PushState] = [:]
        for record in sessions where !record.info.archived && !record.info.ended {
            let info = record.info
            var state = PushState(busy: info.busy, waiting: info.pendingApproval != nil, failed: record.error != nil, goal: info.goal)
            let old = pushStates[info.id]
            state.goalSince = info.goal == nil ? nil : (old?.goal == info.goal ? old?.goalSince : Date().timeIntervalSince1970)
            next[info.id] = state
            guard let old else { continue }
            let name = Self.pushName(for: info)
            if state.waiting, !old.waiting {
                push(name, "Waiting for approval", session: info.id, kind: "waiting")
            }
            if state.failed, !old.failed {
                push(name, "Stopped with an error", session: info.id, kind: "failed")
            } else if let goal = old.goal, state.goal == nil {
                // Met, not cleared by the user: the latest goal row is a met one.
                if record.goalWasMet(goal) {
                    let taken = old.goalSince.map { Date().timeIntervalSince1970 - $0 }
                    push(name, "Goal achieved" + (taken.map { " in " + Self.duration($0) } ?? ""), session: info.id, kind: "goal")
                }
            } else if old.busy, !state.busy, !state.waiting {
                push(name, "Turn finished", session: info.id, kind: "turn")
            }
        }
        pushStates = next
    }

    /// What a push calls a session.
    static func pushName(for info: SessionInfo) -> String {
        info.title.isEmpty ? info.agent.title : info.title
    }

    /// "1h45m", "12m", "40s".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let hours = total / 3600, minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h\(String(format: "%02d", minutes))m" : "\(minutes)m"
    }

    /// The platforms APNs reaches.
    static let apnsPlatforms: Set<String> = ["ios", "macos"]

    /// Says one thing to every device that asked, as a push.
    func push(_ title: String, _ body: String, session: String, kind: String) {
        onPush?(title, body, session, kind)
        let devices = pushDevices.filter { Self.apnsPlatforms.contains($0.platform) }
        guard let key = storedAPNsKey, !devices.isEmpty else { return }
        let data = ["computer": pushComputer, "session": session]
        let sender = apnsSender
        Task { [weak self] in
            guard let jwt = try? sender.jwt(for: key) else { return }
            for device in devices {
                guard let request = APNsSender.request(to: device, jwt: jwt, title: title, body: body,
                                                       collapse: session + "/" + kind, data: data) else { continue }
                let status = await sender.send(request)
                // Gone (the app deleted) or not a token APNs knows: forgotten.
                if status == 410 || status == 400 {
                    await MainActor.run {
                        self?.pushDevices.removeAll { $0.token == device.token }
                        self?.keepPushDevices()
                    }
                }
            }
        }
    }

    /// A test, from Settings: to every device, now.
    public func sendTestPush() -> String? {
        guard storedAPNsKey != nil else { return "Set the APNs key first." }
        guard pushDevices.contains(where: { Self.apnsPlatforms.contains($0.platform) }) else {
            return "No device has asked for notifications yet: open Visor on the phone."
        }
        push(hostName, "Notifications from this computer work", session: "", kind: "test")
        return nil
    }

    public var pushDeviceCount: Int { pushDevices.count }
}
