// Push notifications, sent by this server to the devices whose apps gave
// it their tokens: a turn finished, a goal achieved (and how long it took),
// an agent waiting for approval or stopped by an error — so a phone hears
// of it with the app closed. APNs is reached directly, signed with the
// owner's APNs key (Settings → Push Notifications), kept in the keychain.
//
// What a push says is the session's name and a fixed phrase; its data
// names the computer and the session, and carries the session's state in
// a word (working, waiting, goal, idle) and when, so the device can bring
// its widget up to date without opening the app. A change of state that
// is not worth a notification — a turn beginning — goes as a silent push
// with the same data. Nothing the agent or the user said goes to Apple.

import CryptoKit
import Foundation
import VisorProtocol

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
            var said = false
            if state.waiting, !old.waiting {
                push(name, "Waiting for approval", session: info.id, kind: "waiting", status: state.status)
                said = true
            }
            if state.failed, !old.failed {
                push(name, "Stopped with an error", session: info.id, kind: "failed", status: state.status)
                said = true
            } else if let goal = old.goal, state.goal == nil {
                // Met, not cleared by the user: the latest goal row is a met one.
                if record.goalWasMet(goal) {
                    let taken = old.goalSince.map { Date().timeIntervalSince1970 - $0 }
                    push(name, "Goal achieved" + (taken.map { " in " + Self.duration($0) } ?? ""), session: info.id, kind: "goal",
                         status: state.status)
                    said = true
                }
            } else if old.busy, !state.busy, !state.waiting {
                push(name, "Turn finished", session: info.id, kind: "turn", status: state.status)
                said = true
            }
            // A change nothing was said about (a turn beginning, a goal
            // set): the state alone, silently, for the widget.
            if !said, state.status != old.status { pushStatus(name, session: info.id, status: state.status) }
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

    /// What a push's data says of a session: where it is, and its state
    /// in a word with the session's name and the time, for the widget.
    func pushData(session: String, title: String, status: String?) -> [String: String] {
        var data = ["computer": pushComputer, "session": session]
        guard let status else { return data }
        data["state"] = status
        data["title"] = title
        data["name"] = hostName
        data["updated"] = String(Int(Date().timeIntervalSince1970))
        return data
    }

    /// The session's state alone, to every device that asked: a silent
    /// push, which shows nothing and lets the device update its widget.
    func pushStatus(_ title: String, session: String, status: String) {
        onStatusPush?(session, status)
        deliver(collapse: session + "/status", data: pushData(session: session, title: title, status: status)) { device, jwt, collapse, data in
            APNsSender.statusRequest(to: device, jwt: jwt, collapse: collapse, data: data)
        }
    }

    /// Says one thing to every device that asked, as a push.
    func push(_ title: String, _ body: String, session: String, kind: String, status: String? = nil) {
        onPush?(title, body, session, kind)
        deliver(collapse: session + "/" + kind, data: pushData(session: session, title: title, status: status)) { device, jwt, collapse, data in
            APNsSender.request(to: device, jwt: jwt, title: title, body: body, collapse: collapse, data: data)
        }
    }

    /// Sends one request per device, forgetting a device APNs says is gone.
    private func deliver(collapse: String, data: [String: String],
                         request make: @escaping @Sendable (PushDevice, String, String, [String: String]) -> URLRequest?) {
        let devices = pushDevices.filter { Self.apnsPlatforms.contains($0.platform) }
        guard let key = storedAPNsKey, !devices.isEmpty else { return }
        guard let jwt = try? apnsSender.jwt(for: key) else { return }
        Task {
            for device in devices {
                guard let request = make(device, jwt, collapse, data) else { continue }
                let answer = await apnsSender.send(request)
                if APNsSender.forgets(status: answer.status, reason: answer.reason) {
                    pushDevices.removeAll { $0.token == device.token }
                    keepPushDevices()
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
