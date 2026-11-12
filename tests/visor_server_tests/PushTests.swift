// Pushes: what is said and when, what reaches APNs (a session's name, a
// fixed phrase, the session's id: nothing from the conversation), and the
// token that signs it.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import Testing

extension ServerTests {
@Suite @MainActor final class PushTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-push-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7976)
    }

    private func record(_ id: String, busy: Bool = false) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: "Halo", busy: busy, created: 0),
                      process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
    }

    @Test func testWhatIsSaidAndWhen() {
        var said: [String] = []
        server.onPush = { title, body, _, kind in said.append("\(kind): \(title): \(body)") }
        let working = record("s", busy: true)
        server.sessions = [working]
        server.notifyPushes()
        #expect(said.isEmpty, "the first look says nothing")
        _ = working.apply(.busy(false))
        server.notifyPushes()
        #expect(said == ["turn: Halo: Turn finished"])

        // A goal met, after a while: said with how long it took.
        working.replaceEntriesForTesting([TranscriptEntry(id: "goal-file-1", role: .tool, text: "Secret words", toolName: "goal")])
        server.notifyPushes()
        server.pushStates["s"]?.goalSince = Date().timeIntervalSince1970 - 6300
        working.replaceEntriesForTesting(working.entries + [TranscriptEntry(id: "goal-file-2", role: .tool, text: "Why", toolName: "goal-met")])
        server.notifyPushes()
        #expect(said.last == "goal: Halo: Goal achieved in 1h45m")
        #expect(!(said.contains { $0.contains("Secret words") }), "the goal's words are not said")

        // A goal cleared by the user: nothing.
        working.replaceEntriesForTesting(working.entries + [TranscriptEntry(id: "goal-file-3", role: .tool, text: "Another", toolName: "goal")])
        server.notifyPushes()
        let count = said.count
        working.replaceEntriesForTesting(working.entries + [TranscriptEntry(id: "u", role: .user, text: "/goal clear")])
        server.notifyPushes()
        #expect(said.count == count)
    }

    /// A change of state nothing is said about goes as a silent push, for
    /// the widget; one that is said carries the state with it instead.
    @Test func testAStateChangeAloneIsPushedSilently() {
        var said: [String] = []
        var states: [String] = []
        server.onPush = { _, _, _, kind in said.append(kind) }
        server.onStatusPush = { session, status in states.append(session + ": " + status) }
        let session = record("s")
        server.sessions = [session]
        server.notifyPushes()
        #expect(states.isEmpty, "the first look says nothing")
        _ = session.apply(.busy(true))
        server.notifyPushes()
        #expect(states == ["s: working"])
        #expect(said.isEmpty)
        server.notifyPushes()
        #expect(states.count == 1, "nothing changed, nothing sent")
        _ = session.apply(.busy(false))
        server.notifyPushes()
        #expect(said == ["turn"])
        #expect(states.count == 1, "the notification carries the state itself")
    }

    @Test func testAPushCarriesTheSessionsState() throws {
        let data = server.pushData(session: "s", title: "Halo", status: "working")
        #expect((data["state"]) == "working")
        #expect((data["title"]) == "Halo")
        #expect((data["session"]) == "s")
        #expect((data["updated"].flatMap(Int.init)) != nil)
        #expect((Set(server.pushData(session: "s", title: "Halo", status: nil).keys)) == ["computer", "session"])

        let device = PushDevice(token: "ab12", platform: "ios", environment: "production", topic: "com.example.app", registered: 0)
        let silent = try #require(APNsSender.statusRequest(to: device, jwt: "J", collapse: "s/status", data: data))
        #expect(silent.url == "https://api.push.apple.com/3/device/ab12")
        #expect((silent.headers["apns-push-type"]) == "background")
        #expect((silent.headers["apns-priority"]) == "5")
        let payload = try #require(JSONSerialization.jsonObject(with: silent.body) as? [String: Any])
        #expect(((payload["aps"] as? [String: Any])?.keys.sorted()) == ["content-available"], "nothing shown, no sound")
        #expect((payload["state"] as? String) == "working")
    }

    @Test func testTheRequestCarriesNothingOfTheConversation() throws {
        let device = PushDevice(token: "ab12", platform: "ios", environment: "sandbox", topic: "com.example.app", registered: 0)
        let request = try #require(APNsSender.request(to: device, jwt: "J", title: "Halo", body: "Turn finished",
                                                       collapse: "s/turn", data: ["computer": "mini.ts.net", "session": "s"]))
        #expect(request.url == "https://api.sandbox.push.apple.com/3/device/ab12")
        #expect((request.headers["apns-topic"]) == "com.example.app")
        #expect((request.headers["authorization"]) == "bearer J")
        let payload = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(Set(payload.keys) == ["aps", "computer", "session"])
        let alert = (payload["aps"] as? [String: Any])?["alert"] as? [String: String]
        #expect(alert == ["title": "Halo", "body": "Turn finished"])
    }

    /// A device is forgotten when APNs says its token is no good — not
    /// when the request was refused for the server's own key or topic.
    @Test func testOnlyABadTokenForgetsTheDevice() {
        #expect(APNsSender.forgets(status: 410, reason: "Unregistered"))
        #expect(APNsSender.forgets(status: 400, reason: "BadDeviceToken"))
        #expect(APNsSender.forgets(status: 400, reason: "DeviceTokenNotForTopic"))
        #expect(!APNsSender.forgets(status: 400, reason: "BadTopic"))
        #expect(!APNsSender.forgets(status: 400, reason: nil))
        #expect(!APNsSender.forgets(status: 403, reason: "InvalidProviderToken"))
        #expect(!APNsSender.forgets(status: 200, reason: nil))
        #expect(!APNsSender.forgets(status: 0, reason: nil))
    }

    /// A device that muted a kind of push isn't sent it; the silent state
    /// push still goes to it, and an older client's registration, with no
    /// list, wants every kind.
    @Test func testAMutedKindIsNotSent() {
        var phone = Envelope(type: "push")
        phone.deviceToken = "ab12"; phone.platform = "ios"; phone.pushEnvironment = "sandbox"; phone.pushTopic = "com.example.app"
        phone.pushMuted = [PushKind.turn.rawValue]
        #expect(server.registerPush(phone))
        var older = Envelope(type: "push")
        older.deviceToken = "cd34"; older.platform = "ios"; older.pushEnvironment = "sandbox"; older.pushTopic = "com.example.app"
        #expect(server.registerPush(older))
        #expect((server.pushTargets(kind: PushKind.turn.rawValue).map(\.token)) == ["cd34"])
        #expect((server.pushTargets(kind: PushKind.waiting.rawValue).map(\.token)) == ["ab12", "cd34"])
        #expect((server.pushTargets(kind: nil).map(\.token)) == ["ab12", "cd34"], "the widget's silent push")
        #expect((VisorServer.keptPushDevices().first { $0.token == "ab12" }?.muted) == ["turn"], "kept with the device")

        // Registering again with nothing muted unmutes it.
        phone.pushMuted = []
        #expect(server.registerPush(phone))
        #expect((server.pushTargets(kind: PushKind.turn.rawValue).map(\.token).sorted()) == ["ab12", "cd34"])
    }

    @Test func testDevicesAreKept() {
        var e = Envelope(type: "push")
        e.deviceToken = "ab12"; e.platform = "ios"; e.pushEnvironment = "sandbox"; e.pushTopic = "com.example.app"
        #expect(server.registerPush(e))
        #expect(server.registerPush(e), "again: replaced, not added")
        #expect((VisorServer.keptPushDevices().map(\.token)) == ["ab12"])
        e.deviceToken = "not hex!"
        #expect(!server.registerPush(e), "an Apple token is hex")
        // Another platform registers with its own token and nothing of APNs's.
        var android = Envelope(type: "push")
        android.deviceToken = "fcm:token-1"; android.platform = "android"
        #expect(server.registerPush(android))
        #expect(VisorServer.keptPushDevices().count == 2)
        #expect(VisorServer.duration(40) == "40s")
        #expect(VisorServer.duration(12 * 60) == "12m")
    }
}
}
