// A computer with no APNs key of its own sends its pushes through a push
// proxy that holds the key (Visor Runner's): the same requests, unsigned,
// at the proxy's /apns/<APNs's host>/…, with this server's token for it. The
// proxy is set with the password, never an agent's token, and its token is
// kept with the secrets, never read back.

import Foundation
import Synchronization
import VisorProtocol
@testable import VisorServer
import Testing

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

extension ServerTests {
@Suite @MainActor final class PushProxyTests {
    private var server: VisorServer!
    private let proxy = FakePushProxy()

    init() async throws {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-push-proxy-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        ServerPlatform.current.fetching = proxy
        server = VisorServer(port: ServerTestCase.freePort())
        server.password = "pw"
    }

    isolated deinit {
        server.stop()
    }

    private func setProxy(_ body: String, bearer: String = "pw") -> HTTPResponse {
        server.route(HTTPRequest(method: "PUT", path: "/api/push-proxy", headers: ["authorization": "Bearer " + bearer], body: body))
    }

    private func registerDevice() -> HTTPResponse {
        server.route(HTTPRequest(method: "POST", path: "/api/push", headers: ["authorization": "Bearer pw"],
                                 body: #"{"type":"push","deviceToken":"ab12","platform":"ios","pushEnvironment":"production","pushTopic":"com.example.app"}"#))
    }

    @Test func testARequestGoesToTheProxyUnsigned() throws {
        let device = PushDevice(token: "ab12", platform: "ios", environment: "sandbox", topic: "com.example.app", registered: 0)
        let request = try #require(APNsSender.request(to: device, jwt: "", title: "Halo", body: "Turn finished", collapse: "s/turn",
                                                       data: ["session": "s"]))
        let proxied = try #require(APNsSender.proxied(request, through: "http://192.168.131.1:7439/", token: "tok"))
        #expect(proxied.url == "http://192.168.131.1:7439/apns/api.sandbox.push.apple.com/3/device/ab12")
        #expect((proxied.headers["authorization"]) == nil, "the proxy signs it")
        #expect((proxied.headers[APNsSender.proxyTokenHeader]) == "tok")
        #expect((proxied.headers["apns-topic"]) == "com.example.app")
        #expect((proxied.headers["apns-push-type"]) == "alert")
        #expect(proxied.method == "POST")
        #expect(proxied.body == request.body)
    }

    @Test func testTheProxyIsSetWithThePasswordAndItsTokenKeptApart() throws {
        #expect(setProxy(#"{"url":"http://192.168.131.1:7439","token":"tok"}"#, bearer: server.agentToken).status == 403, "an agent could send the pushes anywhere")
        #expect(server.pushProxy == nil)
        #expect(setProxy(#"{"url":"ftp://proxy"}"#).status == 400)
        #expect(setProxy(#"{"url":"http://192.168.131.1:7439","token":"tok"}"#).status == 200)
        #expect(server.settings.pushProxy == "http://192.168.131.1:7439")
        #expect((server.pushProxy?.token) == "tok")
        let read = server.route(HTTPRequest(method: "GET", path: "/api/push-proxy", headers: ["authorization": "Bearer pw"], body: ""))
        #expect(read.body.contains("\"kept\":true") && !read.body.contains("tok"), Comment(rawValue: read.body))
        // Set again without a token, the token stays; no address, both go.
        #expect(setProxy(#"{"url":"http://192.168.131.1:7440"}"#).status == 200)
        #expect((server.pushProxy?.token) == "tok")
        #expect(setProxy(#"{"url":""}"#).status == 200)
        #expect(server.pushProxy == nil)
        #expect(VisorServer.secrets.get(VisorServer.pushProxyTokenKey) == nil)
    }

    @Test func testWithAProxyPushesGoOutWithoutAKey() async throws {
        #expect(!server.sendsPushes)
        #expect(setProxy(#"{"url":"http://192.168.131.1:7439","token":"tok"}"#).status == 200)
        #expect(server.sendsPushes)
        let registered = registerDevice()
        #expect(registered.status == 200)
        #expect(Envelope.decodeBody(registered.body).exists == true, "the device leaves its notifications to the server")

        server.push("Halo", "Turn finished", session: "s", kind: "turn")
        for _ in 0..<100 where proxy.heard.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(20)) }
        let sent = try #require(proxy.heard.withLock { $0.first })
        #expect(sent.url == "http://192.168.131.1:7439/apns/api.push.apple.com/3/device/ab12")
        #expect((sent.headers[APNsSender.proxyTokenHeader]) == "tok")
        #expect((sent.headers["authorization"]) == nil)
    }

    @Test func testADeviceTheProxySaysIsGoneIsForgotten() async throws {
        #expect(setProxy(#"{"url":"http://192.168.131.1:7439","token":"tok"}"#).status == 200)
        _ = registerDevice()
        proxy.status.withLock { $0 = 400 }
        server.push("Halo", "Turn finished", session: "s", kind: "turn")
        for _ in 0..<100 where server.pushDeviceCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.pushDeviceCount == 0, "APNs's answer, passed on by the proxy, is heard as APNs's")
    }
}
}
