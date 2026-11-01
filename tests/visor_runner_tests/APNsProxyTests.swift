// The Runner's push proxy (docs/co-tenancy.md): a push a server sends here
// unsigned goes on to APNs signed with the key the Runner alone keeps, with
// APNs's own headers only, and APNs's answer comes back as it came. Nothing
// but a push to a device at APNs goes through, and nothing at all without
// a server's token or a key.

import CVisorPOSIX
import Foundation
import Synchronization
import VisorRunner
import XCTest

/// A signature the test can tell: the message's length, 64 times, and how
/// many were made.
private final class FakeSigning: APNsSigning {
    let made = Mutex(0)

    func sign(_ message: Data, with pem: String) throws -> Data {
        made.withLock { $0 += 1 }
        return Data(repeating: UInt8(message.count % 256), count: 64)
    }
}

/// APNs, played by the test: what it was sent, and its answer.
private final class FakeAPNs: Sendable {
    let sent = Mutex<[APNsProxy.Outgoing]>([])
    let answer = Mutex(APNsProxy.Answer(status: 200, body: Data()))

    func send(_ push: APNsProxy.Outgoing) -> APNsProxy.Answer {
        sent.withLock { $0.append(push) }
        return answer.withLock { $0 }
    }
}

final class APNsProxyTests: XCTestCase {
    private let pem = "-----BEGIN PRIVATE KEY-----\nMIGT\n-----END PRIVATE KEY-----"

    private func proxy(key: Bool = true) -> (APNsProxy, FakeAPNs, FakeSigning) {
        let secrets = MemorySecrets()
        if key {
            secrets.set(APNsProxy.keySecret, pem)
            secrets.set(APNsProxy.keyIDSecret, "ABCDEFGHIJ")
            secrets.set(APNsProxy.teamIDSecret, "TEAM123456")
        }
        let apns = FakeAPNs(), signing = FakeSigning()
        return (APNsProxy(secrets: secrets, signing: signing, send: { apns.send($0) }), apns, signing)
    }

    private func listening(_ pushes: APNsProxy) throws -> (MCPProxy, UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 20000...45000)
            if let proxy = MCPProxy(port: port, endpoints: { [] }, admits: { $0 == "server-token" }, pushes: pushes, secret: { _, _ in nil }) {
                proxy.start()
                return (proxy, port)
            }
        }
        throw XCTSkip("no port for the proxy")
    }

    func testAPushGoesOnToAPNsSignedWithTheKeyKeptHere() throws {
        let (pushes, apns, signing) = proxy()
        apns.answer.withLock { $0 = APNsProxy.Answer(status: 410, body: Data(#"{"reason":"Unregistered"}"#.utf8)) }
        let (listener, port) = try listening(pushes)
        defer { listener.stop() }

        let answered = try curl(["-X", "POST", "-H", "X-Visor-Proxy: server-token", "-H", "apns-topic: com.example.app",
                                 "-H", "apns-push-type: alert", "-H", "apns-priority: 10", "-H", "X-Other: no",
                                 "--data-binary", #"{"aps":{}}"#, "http://127.0.0.1:\(port)/apns/api.push.apple.com/3/device/ab12"])
        XCTAssertEqual(answered.status, "410", "APNs's answer, as it came")
        XCTAssertEqual(answered.body, #"{"reason":"Unregistered"}"#)
        let sent = try XCTUnwrap(apns.sent.withLock { $0.first })
        XCTAssertEqual(sent.url, "https://api.push.apple.com/3/device/ab12")
        XCTAssertEqual(sent.body, Data(#"{"aps":{}}"#.utf8))
        XCTAssertEqual(Set(sent.headers.keys), ["apns-topic", "apns-push-type", "apns-priority", "authorization"],
                       "APNs's headers and the signature: not the server's token, nor anything else")
        // The token APNs takes: ES256 with the key's id, from its team.
        let jwt = try XCTUnwrap(sent.headers["authorization"]?.dropFirst("bearer ".count))
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(try decoded(parts[0]) as? [String: String], ["alg": "ES256", "kid": "ABCDEFGHIJ"])
        XCTAssertEqual(try decoded(parts[1])["iss"] as? String, "TEAM123456")

        // Another push: the same token, not signed again.
        _ = try curl(["-X", "POST", "-H", "X-Visor-Proxy: server-token", "--data-binary", "{}",
                      "http://127.0.0.1:\(port)/apns/api.sandbox.push.apple.com/3/device/cd34"])
        XCTAssertEqual(apns.sent.withLock { $0.map(\.url) }.last, "https://api.sandbox.push.apple.com/3/device/cd34")
        XCTAssertEqual(signing.made.withLock { $0 }, 1)
    }

    func testOnlyAPushToADeviceAtAPNsGetsThrough() throws {
        let (pushes, apns, _) = proxy()
        let (listener, port) = try listening(pushes)
        defer { listener.stop() }
        func status(_ path: String, token: String = "server-token", method: String = "POST") throws -> String {
            try curl(["-X", method, "-H", "X-Visor-Proxy: \(token)", "--data-binary", "{}", "http://127.0.0.1:\(port)\(path)"]).status
        }
        XCTAssertEqual(try status("/apns/api.push.apple.com/3/device/ab12", token: "other"), "401")
        XCTAssertEqual(try status("/apns/example.com/3/device/ab12"), "400", "APNs alone")
        XCTAssertEqual(try status("/apns/api.push.apple.com/3/device/not-hex"), "400")
        XCTAssertEqual(try status("/apns/api.push.apple.com/3/device/ab12/more"), "400")
        XCTAssertEqual(try status("/apns/api.push.apple.com/3/device/ab12", method: "GET"), "405")
        XCTAssertTrue(apns.sent.withLock { $0.isEmpty })
    }

    func testWithoutAKeyNothingGoesOut() throws {
        let (pushes, apns, _) = proxy(key: false)
        XCTAssertFalse(pushes.hasKey)
        let (listener, port) = try listening(pushes)
        defer { listener.stop() }
        let answered = try curl(["-X", "POST", "-H", "X-Visor-Proxy: server-token", "--data-binary", "{}",
                                 "http://127.0.0.1:\(port)/apns/api.push.apple.com/3/device/ab12"])
        XCTAssertEqual(answered.status, "503")
        XCTAssertEqual(answered.body, #"{"reason":"NoKey"}"#)
        XCTAssertTrue(apns.sent.withLock { $0.isEmpty })
    }

    private func decoded(_ part: String) throws -> [String: Any] {
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
