// Who gets in: a bearer that is the password, or a token `hello` issued
// — and nobody else, except on the socket file only this user can open,
// where a client through the computer's own SSH is already signed in.
// Without a password the server does not listen at all; with one it
// listens on this computer alone, or on every interface when opened to
// the network, and tells clients an address accordingly.

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import VisorProtocol
@testable import VisorServer
import Synchronization
import VisorSystem
import Foundation
import Testing

extension ServerTests {
@Suite @MainActor final class AuthTests {
    private var server: VisorServer!

    init() async throws {
        TestPlatform.install()
        // Never the real archive: loading it ends the agents it lists.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-auth-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        // Never the real keychain.
        VisorServer.secrets = MemorySecrets()
        VisorServer.socketPathOverride = "/tmp/visor-auth-\(getpid()).sock"
        server = VisorServer(port: ServerTestCase.freePort())
    }

    isolated deinit {
        server.stop()
        VisorServer.socketPathOverride = nil
    }

    private func request(_ path: String, bearer: String? = nil) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let bearer { headers["authorization"] = "Bearer " + bearer }
        return HTTPRequest(method: "GET", path: path, headers: headers, body: "")
    }

    @Test func testNoPasswordMeansNoServer() {
        #expect(server.password == "")
        server.start()
        #expect(!server.listening)
        // Nothing gets in while there is no password.
        #expect((server.route(request("/api/sessions", bearer: "")).status) == 401)
    }

    @Test func testSettingThePasswordStarts() async {
        server.password = "pearl-grove"
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(server.listening)
        // On this computer alone, nothing is said to clients about where.
        #expect(server.reachableAddress == nil)
        #expect(server.connectionCode == nil)
    }

    /// A refusal says whose computer this is, as hello does: a client that
    /// reached it at another computer's path knows the path is wrong.
    @Test func testARefusalSaysWhoseComputerItIs() {
        server.password = "pearl-grove"
        let refused = server.route(request("/api/hello", bearer: "wrong"))
        #expect(refused.status == 401)
        #expect((Envelope.decode(refused.body, defaultType: "reply")?.id) == server.id)
    }

    @Test func testPasswordAndTokenGetIn() async {
        server.password = "pearl-grove"
        #expect((server.route(request("/api/sessions")).status) == 401)
        #expect((server.route(request("/api/sessions", bearer: "wrong")).status) == 401)
        // A header a front might add names nobody to this server.
        var named = request("/api/sessions")
        named.headers["x-forwarded-user"] = "owner@example.com"
        #expect(server.route(named).status == 401)
        #expect((server.route(request("/api/sessions", bearer: "pearl-grove")).status) == 200)

        // hello gives a token the socket (and further calls) take.
        let hello = server.route(request("/api/hello", bearer: "pearl-grove"))
        #expect(hello.status == 200)
        let envelope = Envelope.decode(hello.body)
        #expect((envelope?.type) == "hello")
        let token = envelope?.token ?? ""
        #expect(!token.isEmpty)
        #expect((server.route(request("/api/sessions", bearer: token)).status) == 200)
        #expect((server.route(request("/api/sessions", bearer: token + "x")).status) == 401)
        // Without the password, no token.
        #expect((server.route(request("/api/hello")).status) == 401)
    }

    private func request(_ path: String, bearer: String?, from peer: String?, forwardedFor: String? = nil) -> HTTPRequest {
        var made = request(path, bearer: bearer)
        made.peer = peer
        made.headers["x-forwarded-for"] = forwardedFor
        return made
    }

    /// Five wrong passwords from one address within a minute and it is
    /// answered 429 for five minutes, saying when to try again, whatever it
    /// shows; another address, and this computer, are let in as before.
    @Test func testWrongPasswordsLockTheirAddressOut() {
        let clock = SetTime()
        server.passwordThrottle = PasswordThrottle(now: { clock.now })
        server.password = "pearl-grove"
        let stranger = "192.168.1.66"
        for _ in 0..<PasswordThrottle.allowed {
            #expect(server.route(request("/api/hello", bearer: "amber-birch", from: stranger)).status == 401)
        }
        let locked = server.route(request("/api/hello", bearer: "pearl-grove", from: stranger))
        #expect(locked.status == 429, "not even the password, while it's out")
        #expect(locked.headers["Retry-After"] == "300")
        #expect(locked.body.contains("try again in 300 seconds"))
        #expect(server.route(request("/api/sessions", bearer: "pearl-grove", from: "192.168.1.20")).status == 200, "its owner, beside it")
        #expect(server.route(request("/api/sessions", bearer: "pearl-grove", from: "127.0.0.1")).status == 200)
        for _ in 0..<(PasswordThrottle.allowed * 2) {
            #expect(server.route(request("/api/sessions", bearer: "wrong", from: "127.0.0.1")).status == 401, "this computer is never locked out")
            #expect(server.route(request("/api/sessions", bearer: "wrong", from: nil)).status == 401)
        }
        #expect(server.route(request("/api/sessions", bearer: "pearl-grove", from: nil)).status == 200)
        // No bearer at all is not a guess.
        for _ in 0..<(PasswordThrottle.allowed * 2) {
            #expect(server.route(request("/api/hello", bearer: nil, from: "192.168.1.21")).status == 401)
        }
        #expect(server.route(request("/api/hello", bearer: "pearl-grove", from: "192.168.1.21")).status == 200)

        clock.now = clock.now.addingTimeInterval(PasswordThrottle.lockout)
        #expect(server.route(request("/api/hello", bearer: "pearl-grove", from: stranger)).status == 200, "let in once its time is up")
        // And the right one forgets the wrong ones: four more aren't five.
        for _ in 1..<PasswordThrottle.allowed {
            #expect(server.route(request("/api/hello", bearer: "wrong", from: stranger)).status == 401)
        }
        #expect(server.route(request("/api/hello", bearer: "pearl-grove", from: stranger)).status == 200)
    }

    /// Over the wire: a connection's own address is what is counted, and a
    /// locked-out one is told `429 Too Many Requests` with `Retry-After`.
    @Test func testALockedOutConnectionIsToldWhenToTryAgain() {
        server.password = "pearl-grove"
        #expect(server.http != nil, "the REST side is served")
        func call(_ bearer: String, from address: String) -> String {
            let stream = PeerStream(from: address)
            server.accept(stream)
            stream.arrive("GET /api/hello HTTP/1.1\r\nHost: visor\r\nAuthorization: Bearer \(bearer)\r\n\r\n")
            return String(decoding: stream.sent, as: UTF8.self)
        }
        for _ in 0..<PasswordThrottle.allowed { #expect(call("wrong", from: "2001:db8:0:7::1").hasPrefix("HTTP/1.1 401 ")) }
        let locked = call("pearl-grove", from: "2001:db8:0:7::2")
        #expect(locked.hasPrefix("HTTP/1.1 429 Too Many Requests\r\n"), "its /64 is one address")
        #expect(locked.contains("\r\nRetry-After: 300\r\n"))
        #expect(call("pearl-grove", from: "2001:db8:0:8::1").hasPrefix("HTTP/1.1 200 "))
    }

    /// The socket's login is counted the same, and refused the same while
    /// its address is locked out.
    @Test func testWrongPasswordsAtTheSocketsLoginLockTheAddressOut() {
        server.password = "pearl-grove"
        func login(password: String? = nil, token: String? = nil, from address: String) -> Bool {
            let client = ClientConnection(stream: PeerStream(from: address))
            var envelope = Envelope(type: "login")
            envelope.password = password
            envelope.token = token
            server.handle(envelope, from: client)
            return client.authenticated
        }
        #expect(login(password: "pearl-grove", from: "192.168.1.66"))
        for _ in 0..<(PasswordThrottle.allowed - 1) { #expect(!login(password: "amber-birch", from: "192.168.1.66")) }
        #expect(!login(token: "not-a-token", from: "192.168.1.66"))
        #expect(!login(password: "pearl-grove", from: "192.168.1.66"), "locked out")
        #expect(server.passwordThrottle.retryAfter("192.168.1.66") == 300)
        #expect(login(password: "pearl-grove", from: "192.168.1.67"))
        let hello = Envelope.decode(server.route(request("/api/hello", bearer: "pearl-grove")).body)
        #expect(login(token: hello?.token, from: "192.168.1.68"))
        #expect(!login(token: hello?.token, from: "192.168.1.66"), "not even a token, while it's out")
    }

    /// Behind `tailscale serve` (proxying to loopback, the client in
    /// X-Forwarded-For) each client is counted by its own address, not
    /// let off as this computer; loopback without the header still is, and
    /// the header from anywhere but loopback is never read.
    @Test func testTailscaleServesClientsAreCountedByTheirOwnAddress() {
        server.password = "pearl-grove"
        let tailnet = "100.101.102.103"
        for _ in 0..<PasswordThrottle.allowed {
            #expect(server.route(request("/api/hello", bearer: "amber-birch", from: "127.0.0.1", forwardedFor: tailnet)).status == 401)
        }
        let locked = server.route(request("/api/hello", bearer: "pearl-grove", from: "127.0.0.1", forwardedFor: tailnet))
        #expect(locked.status == 429, "the client tailscale serve named is locked out")
        #expect(locked.headers["Retry-After"] == "300")
        #expect(server.passwordThrottle.retryAfter(tailnet) == 300)
        // Another of its clients is counted on its own.
        #expect(server.route(request("/api/sessions", bearer: "pearl-grove", from: "127.0.0.1", forwardedFor: "100.101.102.104")).status == 200)
        for _ in 1..<PasswordThrottle.allowed {
            #expect(server.route(request("/api/hello", bearer: "wrong", from: "127.0.0.1", forwardedFor: "100.101.102.105")).status == 401)
        }
        #expect(server.route(request("/api/hello", bearer: "pearl-grove", from: "127.0.0.1", forwardedFor: "100.101.102.105")).status == 200)
        // The right-most entry is tailscale serve's: what the client said
        // before it is not who it is.
        #expect(server.route(request("/api/hello", bearer: "pearl-grove", from: "127.0.0.1", forwardedFor: "192.168.1.9, \(tailnet)")).status == 429)
        #expect(server.route(request("/api/hello", bearer: "pearl-grove", from: "::1", forwardedFor: "\(tailnet), 192.168.1.9")).status == 200)
        // This computer without the header is never counted.
        for _ in 0..<(PasswordThrottle.allowed * 2) {
            #expect(server.route(request("/api/sessions", bearer: "wrong", from: "127.0.0.1")).status == 401)
        }
        #expect(server.route(request("/api/sessions", bearer: "pearl-grove", from: "127.0.0.1")).status == 200)
        // From the network the header is the client's word: its own address
        // is what is counted, and the address it names never.
        for _ in 0..<PasswordThrottle.allowed {
            #expect(server.route(request("/api/hello", bearer: "wrong", from: "192.168.1.66", forwardedFor: "192.168.1.20")).status == 401)
        }
        #expect(server.passwordThrottle.retryAfter("192.168.1.66") == 300)
        #expect(server.passwordThrottle.retryAfter("192.168.1.20") == nil)
        #expect(server.route(request("/api/hello", bearer: "pearl-grove", from: "192.168.1.20")).status == 200)
        // Nor can a locked-out address name another to get in.
        #expect(server.route(request("/api/hello", bearer: "pearl-grove", from: "192.168.1.66", forwardedFor: "192.168.1.20")).status == 429)
    }

    /// An IPv6 client tailscale serve names is counted by its /64, as one
    /// that came straight here is.
    @Test func testTailscaleServesIPv6ClientIsCountedByItsSlash64() {
        server.password = "pearl-grove"
        for _ in 0..<PasswordThrottle.allowed {
            #expect(server.route(request("/api/hello", bearer: "wrong", from: "::1", forwardedFor: "2001:db8:0:7::1")).status == 401)
        }
        #expect(server.passwordThrottle.retryAfter("2001:db8:0:7::ffff") == 300)
        #expect(server.route(request("/api/hello", bearer: "pearl-grove", from: "127.0.0.1", forwardedFor: "2001:db8:0:7::2")).status == 429)
        #expect(server.route(request("/api/hello", bearer: "pearl-grove", from: "127.0.0.1", forwardedFor: "2001:db8:0:8::1")).status == 200)
    }

    /// Over the wire, the same: the connection's own address is loopback,
    /// and the request's X-Forwarded-For names the client.
    @Test func testTailscaleServesClientIsCountedOverTheWire() {
        server.password = "pearl-grove"
        #expect(server.http != nil, "the REST side is served")
        func call(_ bearer: String, forwardedFor: String) -> String {
            let stream = PeerStream(from: "127.0.0.1")
            server.accept(stream)
            stream.arrive("GET /api/hello HTTP/1.1\r\nHost: visor\r\nAuthorization: Bearer \(bearer)\r\nX-Forwarded-For: \(forwardedFor)\r\n\r\n")
            return String(decoding: stream.sent, as: UTF8.self)
        }
        for _ in 0..<PasswordThrottle.allowed { #expect(call("wrong", forwardedFor: "203.0.113.7").hasPrefix("HTTP/1.1 401 ")) }
        #expect(call("pearl-grove", forwardedFor: "203.0.113.7").hasPrefix("HTTP/1.1 429 Too Many Requests\r\n"))
        #expect(call("pearl-grove", forwardedFor: "203.0.113.8").hasPrefix("HTTP/1.1 200 "))
    }

    /// The socket's login behind `tailscale serve`: counted by the client
    /// its upgrade's X-Forwarded-For names, over the wire too.
    @Test func testTailscaleServesClientsLoginIsCountedByItsOwnAddress() {
        server.password = "pearl-grove"
        func login(password: String, from address: String, forwardedFor: String? = nil) -> Bool {
            let client = ClientConnection(stream: PeerStream(from: address))
            client.headers["x-forwarded-for"] = forwardedFor
            var envelope = Envelope(type: "login")
            envelope.password = password
            server.handle(envelope, from: client)
            return client.authenticated
        }
        for _ in 0..<PasswordThrottle.allowed { #expect(!login(password: "amber-birch", from: "127.0.0.1", forwardedFor: "100.101.102.103")) }
        #expect(server.passwordThrottle.retryAfter("100.101.102.103") == 300)
        #expect(!login(password: "pearl-grove", from: "127.0.0.1", forwardedFor: "100.101.102.103"), "locked out")
        #expect(login(password: "pearl-grove", from: "127.0.0.1", forwardedFor: "100.101.102.104"), "another of its clients")
        #expect(login(password: "pearl-grove", from: "127.0.0.1"), "this computer")
        for _ in 0..<PasswordThrottle.allowed { #expect(!login(password: "wrong", from: "192.168.1.66", forwardedFor: "192.168.1.20")) }
        #expect(server.passwordThrottle.retryAfter("192.168.1.20") == nil, "the network's word is not read")
        #expect(login(password: "pearl-grove", from: "192.168.1.20"))

        // An upgrade that arrives: its headers are what the login is
        // counted by.
        server.settings.vpn = true
        let stream = PeerStream(from: "127.0.0.1")
        server.accept(stream)
        stream.arrive("GET / HTTP/1.1\r\nHost: visor\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nX-Forwarded-For: 100.101.102.103\r\n\r\n")
        #expect(String(decoding: stream.sent, as: UTF8.self).hasPrefix("HTTP/1.1 101 "))
        let accepted = server.connections.values.first { $0.peer == "127.0.0.1" }
        #expect(accepted?.clientAddress == "100.101.102.103")
    }

    /// With the VPN path off, a tailnet's client is let in through
    /// `tailscale serve` no more than straight to the server: its request
    /// is answered 403 and its upgrade closed. Anyone else on loopback, and
    /// the header from the network, are let in as before.
    @Test func testTailscaleServeKeepsToTheVPNPath() {
        server.password = "pearl-grove"
        server.settings.vpn = false
        #expect(server.http != nil, "the REST side is served")
        func call(from address: String = "127.0.0.1", forwardedFor: String?) -> String {
            let stream = PeerStream(from: address)
            server.accept(stream)
            let header = forwardedFor.map { "X-Forwarded-For: \($0)\r\n" } ?? ""
            stream.arrive("GET /api/hello HTTP/1.1\r\nHost: visor\r\nAuthorization: Bearer pearl-grove\r\n\(header)\r\n")
            return String(decoding: stream.sent, as: UTF8.self)
        }
        func upgrade(forwardedFor: String) -> PeerStream {
            let stream = PeerStream(from: "127.0.0.1")
            server.accept(stream)
            stream.arrive("GET / HTTP/1.1\r\nHost: visor\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nX-Forwarded-For: \(forwardedFor)\r\n\r\n")
            return stream
        }
        let refused = call(forwardedFor: "100.101.102.103")
        #expect(refused.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        #expect(refused.contains(VisorServer.vpnPathOff))
        #expect(call(forwardedFor: "fd7a:115c:a1e0::1234").hasPrefix("HTTP/1.1 403 "), "Tailscale's IPv6 range")
        #expect(call(forwardedFor: nil).hasPrefix("HTTP/1.1 200 "), "this computer")
        #expect(call(forwardedFor: "203.0.113.7").hasPrefix("HTTP/1.1 200 "), "not a tailnet's: a Funnel's, say")
        #expect(call(from: "192.168.1.20", forwardedFor: "100.101.102.103").hasPrefix("HTTP/1.1 200 "), "the network's word is not read")
        let closed = upgrade(forwardedFor: "100.101.102.103")
        #expect(closed.closed)
        #expect(closed.sent.isEmpty)
        #expect(server.connections.isEmpty)

        server.settings.vpn = true
        #expect(call(forwardedFor: "100.101.102.103").hasPrefix("HTTP/1.1 200 "))
        let opened = upgrade(forwardedFor: "100.101.102.103")
        #expect(!opened.closed)
        #expect(String(decoding: opened.sent, as: UTF8.self).hasPrefix("HTTP/1.1 101 "))
        #expect(server.connections.count == 1)
    }

    /// hello says whether clients may keep the sessions' messages on their
    /// disk: only when they may not, so a server from before reads as yes.
    @Test func testHelloAsksClientsToKeepMessagesInMemoryOnlyWhenSet() async throws {
        server.password = "pearl-grove"
        let kept = Envelope.decode(server.route(request("/api/hello", bearer: "pearl-grove")).body)
        #expect((kept?.keepMessages) == nil)
        server.settings.clientsKeepMessages = false
        let inMemory = Envelope.decode(server.route(request("/api/hello", bearer: "pearl-grove")).body)
        #expect((inMemory?.keepMessages) == false)
        let older = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"lan":true}"#.utf8))
        #expect(older.clientsKeepMessages, "a settings file from before lets them")
    }

    /// Opened to the network, the server tells clients its first address
    /// with the port; an address set by hand is told instead.
    @Test func testTheAddressClientsAreTold() async {
        server.password = "pearl-grove"
        server.settings.lan = true
        server.settings.vpn = true
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(server.listening)
        if ServerPlatform.current.host.addresses().isEmpty {
            #expect(server.reachableAddress == nil, "no network at all")
        } else {
            #expect(server.reachableAddress == server.httpPaths.first)
            #expect(server.reachableAddress?.hasSuffix(":\(server.port)") == true)
        }
        // Each path admits its own connections, and only while on.
        #expect(server.admits(localAddress: nil))
        #expect(server.admits(localAddress: "127.0.0.1"))
        #expect(server.admits(localAddress: "192.168.1.20"))
        #expect(server.admits(localAddress: "100.64.0.11"))
        server.settings.lan = false
        #expect(!server.admits(localAddress: "192.168.1.20"))
        #expect(server.admits(localAddress: "100.64.0.11"), "a VPN's range")
        server.settings.vpn = false
        #expect(!server.admits(localAddress: "100.64.0.11"))
        #expect(server.admits(localAddress: "127.0.0.1"), "this computer always")
        #expect(NetworkAddress(address: "10.0.0.5", interface: "utun3").kind == .vpn)
        #expect(NetworkAddress.isLinkLocal("169.254.179.38"))
        #expect(!(ServerPlatform.current.host.networkAddresses().contains { NetworkAddress.isLinkLocal($0.address) }))
        #expect(NetworkAddress(address: "192.168.1.5", interface: "en0").kind == .lan)
        server.settings.lan = true
        server.settings.vpn = true
        server.settings.proxyEnabled = true
        server.settings.publicAddress = "https://proxy.example.com/visor"
        #expect(server.reachableAddress == "https://proxy.example.com/visor")
        #expect((server.connectionCode?.host) == "https://proxy.example.com/visor")
        // Kept, for the next launch.
        #expect(ServerSettings.kept(at: VisorServer.settingsURL).publicAddress == "https://proxy.example.com/visor")
    }

    @Test func testConnectionCodeCarriesAddressAndPassword() async {
        #expect(server.connectionCode == nil)
        server.password = "pearl-grove"
        server.settings.proxyEnabled = true
        server.settings.publicAddress = "this-mac.example.ts.net"
        let code = server.connectionCode
        #expect((code?.host) == "this-mac.example.ts.net")
        #expect((code?.password) == "pearl-grove")
        #expect((code.flatMap { ConnectionCode(parsing: $0.encoded) }) == code)
        #expect((code.flatMap { ConnectionCode(parsing: "  " + $0.link + "\n") }) == code)
    }

    /// A request on a trusted connection (the socket file) needs no
    /// bearer; a login there needs no password; the setting decides
    /// whether the file is served at all, and a settings file from
    /// before it reads as served.
    @Test func testSSHClientsAreTrustedWithoutAPassword() async throws {
        server.password = "pearl-grove"
        var trusted = request("/api/sessions")
        trusted.trusted = true
        #expect(server.route(trusted).status == 200)
        var hello = request("/api/hello")
        hello.trusted = true
        let answer = server.route(hello)
        #expect(answer.status == 200)
        #expect(!(Envelope.decode(answer.body)?.token?.isEmpty ?? true))

        let stream = RecordingStream()
        let client = ClientConnection(stream: stream)
        client.trusted = true
        server.handle(Envelope(type: "login"), from: client)
        #expect(client.authenticated)
        let plain = ClientConnection(stream: RecordingStream())
        server.handle(Envelope(type: "login"), from: plain)
        #expect(!plain.authenticated)

        let older = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"reachableFromNetwork":true,"publicAddress":"https://p.example"}"#.utf8))
        #expect(older.sshEnabled)
        #expect(older.lan && older.vpn, "the network was both paths")
        #expect(older.proxyEnabled, "an address set was a proxy in use")
        var off = ServerSettings()
        off.sshEnabled = false
        let kept = try JSONDecoder().decode(ServerSettings.self, from: JSONEncoder().encode(off))
        #expect(!kept.sshEnabled)
    }

    /// The socket file is there while SSH clients are let in, closed to
    /// everyone but its owner, answers hello with no bearer, and goes
    /// when the setting is turned off.
    @Test func testTheSocketFileAnswersWithoutABearer() async throws {
        server.password = "pearl-grove"
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        let path = VisorServer.socketPath
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: path) { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(FileManager.default.fileExists(atPath: path), Comment(rawValue: path))
        // Closed to others a moment after it is made (bound, then its mode
        // set): read once that has happened, not in between.
        var mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        for _ in 0..<50 where mode.map({ $0 & 0o777 }) != 0o600 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        }
        #expect((mode.map { $0 & 0o777 }) == 0o600)

        // As the client reaches it (`nc -U` on the computer): a connection
        // to the file, HTTP through it, no bearer.
        let answer = await Self.through(path, "GET /api/hello HTTP/1.1\r\nHost: visor\r\n\r\n")
        #expect(answer.hasPrefix("HTTP/1.1 200"), Comment(rawValue: answer))
        #expect(answer.contains("\"hello\""), Comment(rawValue: answer))

        server.settings.sshEnabled = false
        for _ in 0..<50 where FileManager.default.fileExists(atPath: path) { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// Sends `text` down a connection to the socket file and takes what
    /// comes back, off the main actor (the server answers there).
    private static func through(_ path: String, _ text: String) async -> String {
        await Task.detached {
            #if canImport(Glibc)
            let kind = Int32(SOCK_STREAM.rawValue)
            #else
            let kind = SOCK_STREAM
            #endif
            let fd = socket(AF_UNIX, kind, 0)
            guard fd >= 0 else { return "no socket: \(errno)" }
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutablePointer(to: &address.sun_path) { sunPath in
                sunPath.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { return "not connected: \(errno)" }
            _ = text.withCString { write(fd, $0, strlen($0)) }
            var answer = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                answer.append(contentsOf: buffer[..<count])
            }
            return String(decoding: answer, as: UTF8.self)
        }.value
    }
    /// Set to ask nothing, the server lets in whoever reaches it — no
    /// bearer, no password at login — and serves with no password set.
    @Test func testAServerAskingNothingLetsEveryoneIn() async {
        server.settings.authentication = "none"
        for _ in 0..<50 where !server.listening { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(server.listening, "no password, and it serves")
        #expect((server.route(request("/api/sessions")).status) == 200)
        #expect((server.route(request("/api/hello")).status) == 200)
        let client = ClientConnection(stream: RecordingStream())
        server.handle(Envelope(type: "login"), from: client)
        #expect(client.authenticated)
        server.settings.authentication = "password"
        #expect((server.route(request("/api/sessions")).status) == 401)
    }
    /// A client that is in hands its SSH key over: kept once in the
    /// authorized keys, the folder and file closed to others; junk is
    /// refused; a stranger gets nothing. The connection code carries the
    /// server's paths.
    @Test func testADeviceAuthorizesItsSSHKey() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-keys-" + UUID().uuidString)
        VisorServer.authorizedKeysPathOverride = folder.appendingPathComponent("ssh/authorized_keys").path
        defer { VisorServer.authorizedKeysPathOverride = nil }
        server.password = "pearl-grove"
        func post(_ line: String, device: String? = nil, bearer: String? = "pearl-grove", path: String = "/api/ssh/keys") -> Int {
            var body = Envelope(type: "ssh")
            body.text = line
            body.title = device
            var headers: [String: String] = [:]
            if let bearer { headers["authorization"] = "Bearer " + bearer }
            return server.route(HTTPRequest(method: "POST", path: path, headers: headers, body: body.encoded())).status
        }
        let blob = "AAAAC3NzaC1lZDI1NTE5AAAAIGqz1sYyl1Y1kK5lN0w0C5oZ6QwYyq3lQ1kDnq1Z2y7A"
        let key = "ssh-ed25519 \(blob) visor"
        #expect(post(key, device: "Logan's iPhone", bearer: nil) == 401)
        #expect(post(key, device: "Logan's iPhone") == 200)
        #expect(post(key, device: "Logan's iPhone") == 200, "the same key again is no change")
        #expect(post("ssh-ed25519 AAAAother visor") == 200)
        #expect(post("rm -rf /") == 400)
        #expect(post("ssh-ed25519 AAAA$not$base64") == 400)
        #expect(post("ssh-ed25519") == 400)
        var kept = try String(contentsOfFile: VisorServer.authorizedKeysPath, encoding: .utf8)
        // Each line tagged with its device, else its own comment.
        #expect(kept == "ssh-ed25519 \(blob) visor:Logan-s-iPhone\nssh-ed25519 AAAAother visor:visor\n")
        let fileMode = try FileManager.default.attributesOfItem(atPath: VisorServer.authorizedKeysPath)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("ssh").path)[.posixPermissions] as? Int
        #expect((fileMode.map { $0 & 0o777 }) == 0o600)
        #expect((folderMode.map { $0 & 0o777 }) == 0o700)

        // Forget this device: Visor's line goes, one added by hand stays,
        // and 0.64's untagged `visor` line is tagged when it comes again.
        let byHand = "ssh-ed25519 AAAAbyhand me@laptop"
        let older = "ssh-ed25519 AAAAolder visor"
        try (kept + byHand + "\n" + older + "\n").write(toFile: VisorServer.authorizedKeysPath, atomically: true, encoding: .utf8)
        #expect(post(key, path: "/api/ssh/keys/forget") == 200)
        #expect(post("ssh-ed25519 AAAAbyhand", path: "/api/ssh/keys/forget") == 200, "nothing of Visor's to forget")
        #expect(post("ssh-ed25519 AAAAolder", device: "Mini") == 200)
        kept = try String(contentsOfFile: VisorServer.authorizedKeysPath, encoding: .utf8)
        #expect(kept == "ssh-ed25519 AAAAother visor:visor\n\(byHand)\nssh-ed25519 AAAAolder visor:Mini\n")
        #expect(post("ssh-ed25519 AAAAolder", path: "/api/ssh/keys/forget") == 200)
        #expect(post("not a key", path: "/api/ssh/keys/forget") == 400)
        #expect(try String(contentsOfFile: VisorServer.authorizedKeysPath, encoding: .utf8) == "ssh-ed25519 AAAAother visor:visor\n\(byHand)\n")
        #expect(VisorServer.isVisorsKeyLine("ssh-ed25519 AAAA visor:Mini"))
        #expect(VisorServer.isVisorsKeyLine("ssh-ed25519 AAAA visor"))
        #expect(!VisorServer.isVisorsKeyLine("ssh-ed25519 AAAA visor@box"))
        #expect(!VisorServer.isVisorsKeyLine("ssh-ed25519 AAAA my visor"))

        server.settings.proxyEnabled = true
        server.settings.publicAddress = "https://proxy.example.com/visor"
        server.settings.sshEnabled = true
        let code = try #require(server.connectionCode)
        #expect(code.host == "https://proxy.example.com/visor")
        #expect(code.paths == (server.ownAddresses.filter { $0 != code.host }))
        #expect((ConnectionCode(parsing: code.encoded)?.paths) == code.paths)
    }
}
}

/// The time as a test sets it.
@MainActor
private final class SetTime {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

/// A connection from an address on the network: what is sent to it kept,
/// and a way to say something to it.
@MainActor
private final class PeerStream: ByteStream {
    let remoteAddress: String?
    var sent = Data()
    var closed = false
    private var reader: (@MainActor (Data?) -> Void)?

    init(from address: String) { remoteAddress = address }

    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) { reader = chunk }
    func send(_ data: Data, sent: (@MainActor () -> Void)?) { self.sent.append(data); sent?() }
    func close() { closed = true }
    func arrive(_ text: String) { reader?(Data(text.utf8)) }
}

/// A stream that keeps what is sent to it.
@MainActor
private final class RecordingStream: ByteStream {
    var sent: [Data] = []
    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {}
    func send(_ data: Data, sent: (@MainActor () -> Void)?) { self.sent.append(data); sent?() }
    func close() {}
}
