// The agent proxy's resolver: messages read, names routed (the tailnet's to
// Tailscale alone, the rest to the computer's then the fallbacks), answers
// taken or passed over, and the server answering over UDP and TCP. Moved
// from MultiPass's tests (Logan, 2026-11-14).

import Foundation
@testable import VisorAgentProxy
import NIOCore
import NIOPosix
import XCTest

final class DNSTests: XCTestCase {
    // MARK: Messages

    func testAQueryIsReadForItsIdAndLowercasedName() throws {
        let query = try XCTUnwrap(DNSMessage.query(id: 0x1234, name: "Archive.Ubuntu.com"))
        XCTAssertEqual(query.id, 0x1234)
        XCTAssertEqual(query.name, "archive.ubuntu.com")
        XCTAssertFalse(query.isResponse)
        XCTAssertNil(DNSMessage([0, 1, 2]), "shorter than a header")
        XCTAssertNil(DNSMessage(Array(query.bytes.prefix(14))), "a question cut short")
    }

    func testAServerFailureOfItsOwnKeepsTheQuestionAndNothingElse() throws {
        let query = try XCTUnwrap(DNSMessage.query(id: 7, name: "example.com"))
        let failure = query.answer(.serverFailure)
        XCTAssertEqual(failure.id, 7)
        XCTAssertTrue(failure.isResponse)
        XCTAssertEqual(failure.code, .serverFailure)
        XCTAssertEqual(failure.name, "example.com")
        XCTAssertEqual(failure.bytes.count, query.bytes.count)
        XCTAssertEqual(Array(failure.bytes[6..<12]), [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(query.with(id: 9).id, 9)
    }

    func testACompressedNameIsFollowedOnceBackwards() {
        // "a" then a pointer back to "b.c" at offset 12.
        var bytes: [UInt8] = [0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        bytes += [1, 98, 1, 99, 0]  // b.c at 12
        bytes += [0, 1, 0, 1]
        XCTAssertEqual(DNSMessage.readName(bytes + [1, 97, 0xC0, 12], at: 21)?.0, "a.b.c")
        XCTAssertNil(DNSMessage.readName(bytes + [0xC0, 21], at: 21), "a pointer forwards or to itself is refused")
    }

    // MARK: Routes

    func testTheTailnetsNamesGoToTailscaleAloneAndTheRestToTheComputersThenTheFallbacks() {
        let routes = DNSRoutes(tailnet: [.tailscale], system: [DNSUpstream("192.168.4.1"), DNSUpstream("1.1.1.1")])
        XCTAssertEqual(routes.upstreams(for: "mini.tail83099f.ts.net"), [.tailscale])
        XCTAssertEqual(routes.upstreams(for: "TS.NET."), [.tailscale])
        XCTAssertEqual(routes.upstreams(for: "archive.ubuntu.com"),
                       [DNSUpstream("192.168.4.1"), DNSUpstream("1.1.1.1"), DNSUpstream("8.8.8.8")],
                       "each once, in order")
        XCTAssertFalse(routes.isTailnet("notts.net"), "on a label's boundary")
    }

    func testTheComputersResolversAreReadFromResolvConfLessTheProxysOwn() {
        let text = """
        # macOS: this file is not consulted for DNS hostname resolution
        domain tail83099f.ts.net
        nameserver 100.100.100.100
        nameserver fe80::1%en0
        nameserver 192.168.128.1
        nameserver 100.100.100.100
        search example.com
        """
        XCTAssertEqual(SystemResolvers.parse(text, excluding: ["192.168.128.1"]),
                       [DNSUpstream("100.100.100.100"), DNSUpstream("fe80::1")])
    }

    // MARK: The forwarder

    func testTheFirstAnswerThatSaysSomethingIsTakenAndFailuresMoveOn() async throws {
        let upstreams = [DNSUpstream("10.0.0.1"), DNSUpstream("10.0.0.2"), DNSUpstream("10.0.0.3"), DNSUpstream("10.0.0.4")]
        let exchange = ScriptedExchange([
            upstreams[0]: .timeout,
            upstreams[1]: .code(.serverFailure),
            upstreams[2]: .code(.nameError),
            upstreams[3]: .code(.noError),
        ])
        let lines = Lines()
        let forwarder = DNSForwarder(routes: { DNSRoutes(system: Array(upstreams[0...1]), fallbacks: Array(upstreams[2...3])) },
                                     exchange: exchange, log: { lines.add($0) })
        let query = try XCTUnwrap(DNSMessage.query(id: 42, name: "nowhere.example"))
        let answer = try await XCTUnwrapAsync(await forwarder.answer(query))
        XCTAssertEqual(answer.code, .nameError, "no such name is an answer: the fourth isn't asked")
        XCTAssertEqual(answer.id, 42)
        XCTAssertEqual(exchange.asked, Array(upstreams[0...2]))
        XCTAssertEqual(lines.all, ["dns nowhere.example: 10.0.0.3:53 no such name (after 10.0.0.1:53 timed out, 10.0.0.2:53 serverFailure)"])
    }

    func testNoAnswerFromAnyIsAServerFailureOfTheProxysOwn() async throws {
        let exchange = ScriptedExchange([:])
        let forwarder = DNSForwarder(routes: { DNSRoutes(system: [DNSUpstream("10.0.0.1")], fallbacks: [DNSUpstream("10.0.0.2")]) },
                                     exchange: exchange)
        let query = try XCTUnwrap(DNSMessage.query(id: 5, name: "archive.ubuntu.com"))
        let answer = try await XCTUnwrapAsync(await forwarder.answer(query))
        XCTAssertEqual(answer.code, .serverFailure)
        XCTAssertEqual(answer.id, 5)
        XCTAssertEqual(exchange.asked.count, 2)
    }

    func testATailnetNameNeverReachesAPublicResolver() async throws {
        let exchange = ScriptedExchange([:])
        let forwarder = DNSForwarder(routes: { DNSRoutes(tailnet: [.tailscale], system: [DNSUpstream("192.168.4.1")]) }, exchange: exchange)
        let query = try XCTUnwrap(DNSMessage.query(id: 1, name: "mini.tail83099f.ts.net"))
        _ = await forwarder.answer(query)
        XCTAssertEqual(exchange.asked, [.tailscale])
    }

    /// NCH's review of #414: by default (the agent proxy's settings as they
    /// come) no tailnet name is asked of anyone, Tailscale's resolver
    /// included; it is answered no such name. Other names go on as before.
    func testByDefaultATailnetNameIsWithheldAndNeverSentToTheTailnetsResolver() async throws {
        let settings = DNSSettings(hosts: [])
        XCTAssertEqual(settings.tailnet, [], "opt-in")
        let routes = settings.routes(system: [DNSUpstream("100.100.100.100"), DNSUpstream("192.168.4.1")])
        XCTAssertTrue(routes.withholds("mini.tail83099f.ts.net"))
        XCTAssertEqual(routes.upstreams(for: "mini.tail83099f.ts.net"), [])
        let exchange = ScriptedExchange([:], answer: { $0.answer(.noError) })
        let lines = Lines()
        let forwarder = DNSForwarder(routes: { routes }, exchange: exchange, log: { lines.add($0) })
        let query = try XCTUnwrap(DNSMessage.query(id: 3, name: "mini.tail83099f.ts.net"))
        let answer = try await XCTUnwrapAsync(await forwarder.answer(query))
        XCTAssertEqual(answer.code, .nameError)
        XCTAssertEqual(answer.id, 3)
        XCTAssertEqual(exchange.asked, [], "nobody asked, Tailscale's resolver least of all")
        XCTAssertEqual(lines.all, ["dns mini.tail83099f.ts.net: the tailnet's, withheld"])
        let other = try XCTUnwrap(DNSMessage.query(id: 4, name: "archive.ubuntu.com"))
        _ = await forwarder.answer(other)
        XCTAssertEqual(exchange.asked, [DNSUpstream("100.100.100.100")], "anything else to the computer's own, first")
        let optedIn = DNSSettings(hosts: [], tailnet: [DNSUpstream.tailscale.host]).routes(system: [])
        XCTAssertEqual(optedIn.upstreams(for: "mini.tail83099f.ts.net"), [.tailscale], "opted in")
    }

    func testAResponseIsNotForwarded() async throws {
        let forwarder = DNSForwarder(routes: { DNSRoutes(system: [DNSUpstream("10.0.0.1")]) }, exchange: ScriptedExchange([:]))
        let response = try XCTUnwrap(DNSMessage.query(id: 1, name: "a.example")).answer(.noError)
        let answer = await forwarder.answer(response)
        XCTAssertNil(answer)
    }

    // MARK: Over the network

    /// A front server asks an upstream one over the network (NIODNSExchange),
    /// over UDP; a truncated answer is asked for again over TCP.
    func testAServerWhoseTCPPortIsTakenThrowsWithoutTrapping() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("DNSServer is macOS 14's") }
        // A TCP listener holds the port; the server's UDP one is had, its
        // TCP one is not, and what it made is closed before it throws.
        let holder = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        defer { holder.close(promise: nil) }
        let port = try XCTUnwrap(holder.localAddress?.port)
        let forwarder = DNSForwarder(routes: { DNSRoutes(system: [], fallbacks: []) }, exchange: NIODNSExchange())
        do {
            _ = try await DNSServer(hosts: ["127.0.0.1"], port: port, forwarder: forwarder)
            XCTFail("the port was taken")
        } catch {}
    }

    /// A server its owner drops without serving (here, as when the next
    /// server can't be had and the test throws): its listeners are closed,
    /// and NIO's writers don't trap.
    func testAServerDroppedWithoutServingClosesWithoutTrapping() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("DNSServer is macOS 14's") }
        let forwarder = DNSForwarder(routes: { DNSRoutes(system: [], fallbacks: []) }, exchange: NIODNSExchange())
        var server: DNSServer? = try await DNSServer(hosts: ["127.0.0.1"], port: 0, forwarder: forwarder)
        XCTAssertEqual(server?.addresses.count, 1)
        server = nil
        XCTAssertNil(server)
    }

    func testTheServerAnswersOverUDPAndTCPAndATruncatedAnswerIsAskedAgainOverTCP() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("DNSServer is macOS 14's") }
        let upstreamExchange = ScriptedExchange([:], answer: { query in
            var answer = query.answer(.noError)
            if query.name == "big.example" { answer = DNSMessage(Self.truncating(answer.bytes)) ?? answer }
            return answer
        })
        let upstream = try await DNSServer(hosts: ["127.0.0.1"], port: 0,
                                           forwarder: DNSForwarder(routes: { DNSRoutes(system: [DNSUpstream("10.9.9.9")], fallbacks: []) },
                                                                   exchange: upstreamExchange))
        let upstreamPort = try XCTUnwrap(upstream.addresses.first?.port)
        let front = try await DNSServer(hosts: ["127.0.0.1"], port: 0,
                                        forwarder: DNSForwarder(routes: { DNSRoutes(system: [DNSUpstream("127.0.0.1", port: upstreamPort)], fallbacks: []) },
                                                                exchange: NIODNSExchange()))
        let frontPort = try XCTUnwrap(front.addresses.first?.port)
        let serving = Task {
            async let one: Void = upstream.run()
            async let two: Void = front.run()
            _ = await (one, two)
        }

        let exchange = NIODNSExchange()
        let small = try XCTUnwrap(DNSMessage.query(id: 11, name: "small.example"))
        let viaUDP = try await exchange.exchange(small, with: DNSUpstream("127.0.0.1", port: frontPort), timeout: .seconds(5))
        XCTAssertEqual(viaUDP.id, 11)
        XCTAssertEqual(viaUDP.code, .noError)
        XCTAssertEqual(viaUDP.name, "small.example")

        let big = try XCTUnwrap(DNSMessage.query(id: 12, name: "big.example"))
        let viaTCP = try await exchange.exchange(big, with: DNSUpstream("127.0.0.1", port: frontPort), timeout: .seconds(5))
        XCTAssertEqual(viaTCP.id, 12)
        // The front asked the upstream twice for it (UDP, then TCP), and was
        // itself asked twice (the same, by this test's exchange).
        XCTAssertEqual(upstreamExchange.asked.count, 1 + 4, "small once; big over UDP and TCP, front and back")

        await front.close()
        await upstream.close()
        await serving.value
    }

    /// The same answer, marked truncated.
    private static func truncating(_ bytes: [UInt8]) -> [UInt8] {
        var bytes = bytes
        bytes[2] |= 0x02
        return bytes
    }
}

/// A stand-in for the network: each upstream's answer as the test says,
/// and who was asked, in order.
private final class ScriptedExchange: DNSExchanging {
    enum Reply { case timeout, code(DNSMessage.Code) }
    private let replies: [DNSUpstream: Reply]
    private let answer: (@Sendable (DNSMessage) -> DNSMessage)?
    private let log = Locked<[DNSUpstream]>([])

    init(_ replies: [DNSUpstream: Reply], answer: (@Sendable (DNSMessage) -> DNSMessage)? = nil) {
        self.replies = replies
        self.answer = answer
    }

    var asked: [DNSUpstream] { log.withLock { $0 } }

    func exchange(_ query: DNSMessage, with upstream: DNSUpstream, timeout: Duration) async throws -> DNSMessage {
        log.withLock { $0.append(upstream) }
        if let answer { return answer(query) }
        switch replies[upstream] {
        case .code(let code)?: return query.answer(code)
        case .timeout?, nil: throw DNSTimeout()
        }
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
