// Pushes: what is said and when, what reaches APNs (a session's name, a
// fixed phrase, the session's id: nothing from the conversation), and the
// token that signs it.

import CryptoKit
import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class PushTests: XCTestCase {
    private var server: VisorServer!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-push-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: 7976)
        server.exposure = FakeExposure()
    }

    private func record(_ id: String, busy: Bool = false) -> SessionRecord {
        SessionRecord(info: SessionInfo(id: id, agent: .claude, cwd: "/tmp", title: "Isomer", busy: busy, created: 0),
                      process: ClaudeProcess(cwd: "/tmp", skipPermissions: true, resume: nil), entries: [])
    }

    func testWhatIsSaidAndWhen() {
        var said: [String] = []
        server.onPush = { title, body, _, kind in said.append("\(kind): \(title): \(body)") }
        let working = record("s", busy: true)
        server.sessions = [working]
        server.notifyPushes()
        XCTAssertTrue(said.isEmpty, "the first look says nothing")
        _ = working.apply(.busy(false))
        server.notifyPushes()
        XCTAssertEqual(said, ["turn: Isomer: Turn finished"])

        // A goal met, after a while: said with how long it took.
        working.replaceEntriesForTesting([TranscriptEntry(id: "goal-file-1", role: .tool, text: "Secret words", toolName: "goal")])
        server.notifyPushes()
        server.pushStates["s"]?.goalSince = Date().timeIntervalSince1970 - 6300
        working.replaceEntriesForTesting(working.entries + [TranscriptEntry(id: "goal-file-2", role: .tool, text: "Why", toolName: "goal-met")])
        server.notifyPushes()
        XCTAssertEqual(said.last, "goal: Isomer: Goal achieved in 1h45m")
        XCTAssertFalse(said.contains { $0.contains("Secret words") }, "the goal's words are not said")

        // A goal cleared by the user: nothing.
        working.replaceEntriesForTesting(working.entries + [TranscriptEntry(id: "goal-file-3", role: .tool, text: "Another", toolName: "goal")])
        server.notifyPushes()
        let count = said.count
        working.replaceEntriesForTesting(working.entries + [TranscriptEntry(id: "u", role: .user, text: "/goal clear")])
        server.notifyPushes()
        XCTAssertEqual(said.count, count)
    }

    func testTheRequestCarriesNothingOfTheConversation() throws {
        let device = PushDevice(token: "ab12", platform: "ios", environment: "sandbox", topic: "com.example.app", registered: 0)
        let request = try XCTUnwrap(APNsSender.request(to: device, jwt: "J", title: "Isomer", subtitle: "Logan's Mac Mini", body: "Turn finished",
                                                       collapse: "s/turn", data: ["computer": "mini.ts.net", "session": "s"]))
        XCTAssertEqual(request.url?.absoluteString, "https://api.sandbox.push.apple.com/3/device/ab12")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "com.example.app")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "bearer J")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["aps", "computer", "session"])
        let alert = (payload["aps"] as? [String: Any])?["alert"] as? [String: String]
        XCTAssertEqual(alert, ["title": "Isomer", "subtitle": "Logan's Mac Mini", "body": "Turn finished"])
        // What opens it: the session, on its computer.
        XCTAssertEqual(payload["session"] as? String, "s")
        XCTAssertEqual(payload["computer"] as? String, "mini.ts.net")
    }

    func testTheSigningTokenVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let jwt = try APNsSender().jwt(for: APNsKey(pem: key.pemRepresentation, keyID: "ABCDEFGHIJ", teamID: "TEAMTEAM12"))
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func decode(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)!
        }
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: String]
        XCTAssertEqual(header, ["alg": "ES256", "kid": "ABCDEFGHIJ"])
    }

    func testDevicesAreKept() {
        var e = Envelope(type: "push")
        e.deviceToken = "ab12"; e.platform = "ios"; e.pushEnvironment = "sandbox"; e.pushTopic = "com.example.app"
        XCTAssertTrue(server.registerPush(e))
        XCTAssertTrue(server.registerPush(e), "again: replaced, not added")
        XCTAssertEqual(VisorServer.keptPushDevices().map(\.token), ["ab12"])
        e.deviceToken = "not hex!"
        XCTAssertFalse(server.registerPush(e), "an Apple token is hex")
        // Another platform registers with its own token and nothing of APNs's.
        var android = Envelope(type: "push")
        android.deviceToken = "fcm:token-1"; android.platform = "android"
        XCTAssertTrue(server.registerPush(android))
        XCTAssertEqual(VisorServer.keptPushDevices().count, 2)
        XCTAssertEqual(VisorServer.duration(40), "40s")
        XCTAssertEqual(VisorServer.duration(12 * 60), "12m")
    }
}

/// The APNs key can be set over the REST side by whoever is let in, and
/// is never answered back.
@MainActor
final class PushKeyRouteTests: XCTestCase {
    func testTheKeyIsSetOverREST() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-pushkey-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        let server = VisorServer(port: 7974)
        server.exposure = FakeExposure()
        server.password = "pw"
        defer { server.stop() }
        func post(_ path: String, _ body: String, bearer: String = "pw") -> HTTPResponse {
            server.route(HTTPRequest(method: "POST", path: path, headers: ["authorization": "Bearer " + bearer], body: body))
        }
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let body = String(decoding: try! JSONSerialization.data(withJSONObject: ["key": pem, "keyID": "ABCDEFGHIJ", "teamID": "TEAMTEAM12"]), as: UTF8.self)
        XCTAssertEqual(post("/api/push/key", body, bearer: "wrong").status, 401)
        XCTAssertEqual(post("/api/push/key", #"{"key":"nonsense","keyID":"ABCDEFGHIJ","teamID":"TEAMTEAM12"}"#).status, 400)
        let set = post("/api/push/key", body)
        XCTAssertEqual(set.status, 200)
        XCTAssertFalse(set.body.contains("PRIVATE KEY"), "the key is not answered back")
        XCTAssertEqual(server.apnsKey.keyID, "ABCDEFGHIJ")
        XCTAssertTrue(server.apnsKey.configured)
        XCTAssertEqual(post("/api/push/test", "").status, 400, "no device yet")
    }
}
