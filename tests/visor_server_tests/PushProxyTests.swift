// A computer with no APNs key of its own sends its pushes through a push
// proxy that holds the key (Visor Runner's): the same requests, unsigned,
// at the proxy's /apns/<APNs's host>/…, with this server's token for it. The
// proxy is set with the password, never an agent's token, and its token is
// kept with the secrets, never read back.

import Foundation
import Synchronization
import VisorProtocol
@testable import VisorServer
import XCTest

/// The push proxy, played by the test: what it was sent, kept; APNs's
/// answer as the test sets it.
private final class FakePushProxy: HTTPFetching {
    let heard = Mutex<[OutgoingRequest]>([])
    let status = Mutex(200)

    func fetch(_ request: OutgoingRequest) async throws -> OutgoingRequest.Answer {
        heard.withLock { $0.append(request) }
        let status = status.withLock { $0 }
        let body = status == 200 ? Data() : Data(#"{"reason":"BadDeviceToken"}"#.utf8)
        return .init(status: status, body: body)
    }
}

@MainActor
final class PushProxyTests: ServerTestCase {
    private var server: VisorServer!
    private let proxy = FakePushProxy()

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-push-proxy-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        ServerPlatform.current.fetching = proxy
        server = VisorServer(port: 7975)
        server.password = "pw"
    }

    override func tearDown() async throws {
        server.stop()
    }

    private func setProxy(_ body: String, bearer: String = "pw") -> HTTPResponse {
        server.route(HTTPRequest(method: "PUT", path: "/api/push-proxy", headers: ["authorization": "Bearer " + bearer], body: body))
    }

    private func registerDevice() -> HTTPResponse {
        server.route(HTTPRequest(method: "POST", path: "/api/push", headers: ["authorization": "Bearer pw"],
                                 body: #"{"type":"push","deviceToken":"ab12","platform":"ios","pushEnvironment":"production","pushTopic":"com.example.app"}"#))
    }

    func testARequestGoesToTheProxyUnsigned() throws {
        let device = PushDevice(token: "ab12", platform: "ios", environment: "sandbox", topic: "com.example.app", registered: 0)
        let request = try XCTUnwrap(APNsSender.request(to: device, jwt: "", title: "Halo", body: "Turn finished", collapse: "s/turn",
                                                       data: ["session": "s"]))
        let proxied = try XCTUnwrap(APNsSender.proxied(request, through: "http://192.168.131.1:7439/", token: "tok"))
        XCTAssertEqual(proxied.url, "http://192.168.131.1:7439/apns/api.sandbox.push.apple.com/3/device/ab12")
        XCTAssertNil(proxied.headers["authorization"], "the proxy signs it")
        XCTAssertEqual(proxied.headers[APNsSender.proxyTokenHeader], "tok")
        XCTAssertEqual(proxied.headers["apns-topic"], "com.example.app")
        XCTAssertEqual(proxied.headers["apns-push-type"], "alert")
        XCTAssertEqual(proxied.method, "POST")
        XCTAssertEqual(proxied.body, request.body)
    }

    func testTheProxyIsSetWithThePasswordAndItsTokenKeptApart() throws {
        XCTAssertEqual(setProxy(#"{"url":"http://192.168.131.1:7439","token":"tok"}"#, bearer: server.agentToken).status, 403,
                       "an agent could send the pushes anywhere")
        XCTAssertNil(server.pushProxy)
        XCTAssertEqual(setProxy(#"{"url":"ftp://proxy"}"#).status, 400)
        XCTAssertEqual(setProxy(#"{"url":"http://192.168.131.1:7439","token":"tok"}"#).status, 200)
        XCTAssertEqual(server.settings.pushProxy, "http://192.168.131.1:7439")
        XCTAssertEqual(server.pushProxy?.token, "tok")
        let read = server.route(HTTPRequest(method: "GET", path: "/api/push-proxy", headers: ["authorization": "Bearer pw"], body: ""))
        XCTAssertTrue(read.body.contains("\"kept\":true") && !read.body.contains("tok"), read.body)
        // Set again without a token, the token stays; no address, both go.
        XCTAssertEqual(setProxy(#"{"url":"http://192.168.131.1:7440"}"#).status, 200)
        XCTAssertEqual(server.pushProxy?.token, "tok")
        XCTAssertEqual(setProxy(#"{"url":""}"#).status, 200)
        XCTAssertNil(server.pushProxy)
        XCTAssertNil(VisorServer.secrets.get(VisorServer.pushProxyTokenKey))
    }

    func testWithAProxyPushesGoOutWithoutAKey() async throws {
        XCTAssertFalse(server.sendsPushes)
        XCTAssertEqual(setProxy(#"{"url":"http://192.168.131.1:7439","token":"tok"}"#).status, 200)
        XCTAssertTrue(server.sendsPushes)
        let registered = registerDevice()
        XCTAssertEqual(registered.status, 200)
        XCTAssertEqual(Envelope.decodeBody(registered.body).exists, true, "the device leaves its notifications to the server")

        server.push("Halo", "Turn finished", session: "s", kind: "turn")
        for _ in 0..<100 where proxy.heard.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(20)) }
        let sent = try XCTUnwrap(proxy.heard.withLock { $0.first })
        XCTAssertEqual(sent.url, "http://192.168.131.1:7439/apns/api.push.apple.com/3/device/ab12")
        XCTAssertEqual(sent.headers[APNsSender.proxyTokenHeader], "tok")
        XCTAssertNil(sent.headers["authorization"])
    }

    func testADeviceTheProxySaysIsGoneIsForgotten() async throws {
        XCTAssertEqual(setProxy(#"{"url":"http://192.168.131.1:7439","token":"tok"}"#).status, 200)
        _ = registerDevice()
        proxy.status.withLock { $0 = 400 }
        server.push("Halo", "Turn finished", session: "s", kind: "turn")
        for _ in 0..<100 where server.pushDeviceCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(server.pushDeviceCount, 0, "APNs's answer, passed on by the proxy, is heard as APNs's")
    }
}
