// How many wrong passwords an address may show: five within a minute, the
// fifth locking it out for five minutes; counted per address (an IPv6 one
// by its /64), a success forgetting them, this computer never counted, and
// no more than so many addresses kept.

import Foundation
@testable import VisorServer
import Testing

/// The time as a test sets it.
private final class SetClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func pass(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// A throttle held by reference, so what it is asked can be asked within
/// `#expect`.
private final class Held {
    private var throttle: PasswordThrottle
    init(_ throttle: PasswordThrottle) { self.throttle = throttle }
    func failed(_ address: String?) -> Bool { throttle.failed(address) }
    func succeeded(_ address: String?) { throttle.succeeded(address) }
    func retryAfter(_ address: String?) -> Int? { throttle.retryAfter(address) }
    var trackedCount: Int { throttle.trackedCount }
}

extension ServerTests {
@Suite @MainActor struct PasswordThrottleTests {
    private let clock = SetClock()

    private func freshThrottle() -> Held {
        Held(PasswordThrottle(now: { [clock] in clock.now }))
    }

    @Test func testTheFifthWrongPasswordInAMinuteLocksTheAddressOut() {
        let throttle = freshThrottle()
        for _ in 1..<PasswordThrottle.allowed {
            #expect(!throttle.failed("192.168.1.50"))
            #expect(throttle.retryAfter("192.168.1.50") == nil)
        }
        #expect(throttle.failed("192.168.1.50"), "the fifth locks it out, and says so once")
        #expect(throttle.retryAfter("192.168.1.50") == 300)
        #expect(!throttle.failed("192.168.1.50"), "nothing more is counted while it's out")
        #expect(throttle.retryAfter("192.168.1.51") == nil, "another address is not")
        clock.pass(299.5)
        #expect(throttle.retryAfter("192.168.1.50") == 1, "Retry-After rounds up")
        clock.pass(0.5)
        #expect(throttle.retryAfter("192.168.1.50") == nil)
        #expect(!throttle.failed("192.168.1.50"), "counted afresh after a lockout")
    }

    @Test func testWrongPasswordsSpreadOverMoreThanAMinuteAreCountedAfresh() {
        let throttle = freshThrottle()
        for _ in 1..<PasswordThrottle.allowed { #expect(!throttle.failed("10.0.0.7")) }
        clock.pass(PasswordThrottle.window)
        #expect(!throttle.failed("10.0.0.7"), "the window has gone by")
        for _ in 2..<PasswordThrottle.allowed { #expect(!throttle.failed("10.0.0.7")) }
        #expect(throttle.failed("10.0.0.7"))
    }

    @Test func testASuccessForgetsTheWrongOnes() {
        let throttle = freshThrottle()
        for _ in 1..<PasswordThrottle.allowed { #expect(!throttle.failed("10.0.0.7")) }
        throttle.succeeded("10.0.0.7")
        for _ in 1..<PasswordThrottle.allowed { #expect(!throttle.failed("10.0.0.7")) }
        #expect(throttle.retryAfter("10.0.0.7") == nil)
        #expect(throttle.failed("10.0.0.7"))
    }

    @Test func testThisComputerAndTheSocketFileAreNeverCounted() {
        let throttle = freshThrottle()
        for address in ["127.0.0.1", "127.0.0.2", "::1", "0:0:0:0:0:0:0:1", "::ffff:127.0.0.1", "", nil] as [String?] {
            for _ in 0..<(PasswordThrottle.allowed * 2) { #expect(!throttle.failed(address)) }
            #expect(throttle.retryAfter(address) == nil)
        }
        #expect(throttle.trackedCount == 0)
    }

    @Test func testAnIPv6AddressIsCountedByItsSlash64() {
        #expect(PasswordThrottle.key("2001:db8:0:1::5") == "2001:db8:0:1::/64")
        #expect(PasswordThrottle.key("2001:DB8:0:1:aaaa:bbbb:cccc:dddd%en0") == "2001:db8:0:1::/64")
        #expect(PasswordThrottle.key("[2001:db8::1]") == "2001:db8:0:0::/64")
        #expect(PasswordThrottle.key("fe80::1%en0") == "fe80:0:0:0::/64")
        #expect(PasswordThrottle.key("::ffff:192.168.1.5") == "192.168.1.5", "IPv4 in IPv6, as IPv4")
        #expect(PasswordThrottle.key("64:ff9b::192.168.1.5") == "64:ff9b:0:0::/64")
        #expect(PasswordThrottle.key("192.168.1.5") == "192.168.1.5")
        #expect(PasswordThrottle.groups(ipv6: "1:2:3:4:5:6:7:8") == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(PasswordThrottle.groups(ipv6: "1::8") == [1, 0, 0, 0, 0, 0, 0, 8])
        #expect(PasswordThrottle.groups(ipv6: "::") == [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(PasswordThrottle.groups(ipv6: "1:2:3:4:5:6:7:8:9") == nil)
        #expect(PasswordThrottle.groups(ipv6: "1::2::3") == nil)
        #expect(PasswordThrottle.groups(ipv6: "12345::1") == nil)

        let throttle = freshThrottle()
        // A device takes what addresses it likes within its /64: all one.
        for host in 1..<PasswordThrottle.allowed { #expect(!throttle.failed("2001:db8:0:1::\(host)")) }
        #expect(throttle.failed("2001:db8:0:1:ffff::1"))
        #expect(throttle.retryAfter("2001:db8:0:1::abcd") == 300)
        #expect(throttle.retryAfter("2001:db8:0:2::1") == nil, "the next /64 is another")
    }

    @Test func testNoMoreThanSoManyAddressesAreKeptTheOldestGoingFirst() {
        let throttle = freshThrottle()
        // The first address, locked out, then as many more as are kept.
        for _ in 0..<PasswordThrottle.allowed { _ = throttle.failed("10.1.0.1") }
        #expect(throttle.retryAfter("10.1.0.1") != nil)
        for index in 1..<PasswordThrottle.tracked {
            clock.pass(0.01)
            _ = throttle.failed("10.2.\(index / 256).\(index % 256)")
        }
        #expect(throttle.trackedCount == PasswordThrottle.tracked)
        clock.pass(0.01)
        _ = throttle.failed("10.3.0.1")
        #expect(throttle.trackedCount == PasswordThrottle.tracked)
        #expect(throttle.retryAfter("10.1.0.1") == nil, "the oldest went")
        // Those whose count is over go before any other.
        clock.pass(PasswordThrottle.window)
        _ = throttle.failed("10.3.0.2")
        #expect(throttle.trackedCount <= 2)
    }

    /// Who a request is taken as coming from: on loopback with
    /// X-Forwarded-For (tailscale serve's), the header's right-most entry;
    /// anywhere else, or without it, the connection's own address.
    @Test func testTheClientAFrontOnThisComputerNames() {
        let named = ["x-forwarded-for": "100.101.102.103"]
        #expect(ForwardedFor.client(peer: "127.0.0.1", headers: named) == "100.101.102.103")
        #expect(ForwardedFor.client(peer: "::1", headers: named) == "100.101.102.103")
        #expect(ForwardedFor.client(peer: "::ffff:127.0.0.1", headers: named) == "100.101.102.103")
        #expect(ForwardedFor.client(peer: "127.0.0.1", headers: ["x-forwarded-for": "10.0.0.1, 100.101.102.103"]) == "100.101.102.103")
        #expect(ForwardedFor.client(peer: "127.0.0.1", headers: ["x-forwarded-for": "fd7a:115c:a1e0::1234"]) == "fd7a:115c:a1e0::1234")
        #expect(ForwardedFor.client(peer: "127.0.0.1", headers: [:]) == "127.0.0.1")
        #expect(ForwardedFor.client(peer: "127.0.0.1", headers: ["x-forwarded-for": " "]) == "127.0.0.1")
        #expect(ForwardedFor.client(peer: "192.168.1.66", headers: named) == "192.168.1.66", "the network's word is not read")
        #expect(ForwardedFor.client(peer: nil, headers: named) == nil, "the socket file")
        // Counted as any address is: a loopback the header names is still
        // this computer's own, an IPv6 one by its /64.
        #expect(PasswordThrottle.key(ForwardedFor.client(peer: "127.0.0.1", headers: ["x-forwarded-for": "127.0.0.1"])) == nil)
        #expect(PasswordThrottle.key(ForwardedFor.client(peer: "127.0.0.1", headers: ["x-forwarded-for": "2001:db8:0:7::1"])) == "2001:db8:0:7::/64")
    }

    @Test func testATailnetsIPv6AddressIsCountedWhole() {
        #expect(PasswordThrottle.key("fd7a:115c:a1e0:ab12:4843:cd96:6265:6667") == "fd7a:115c:a1e0:ab12:4843:cd96:6265:6667")
        #expect(PasswordThrottle.key("[FD7A:115C:A1E0::1]") == "fd7a:115c:a1e0:0:0:0:0:1", "one address, however written")
        #expect(PasswordThrottle.key("fd7a:115c:a1e0:0:0:0:0:1") == "fd7a:115c:a1e0:0:0:0:0:1")
        #expect(PasswordThrottle.key("fd7a:115c:a1e1::1") == "fd7a:115c:a1e1:0::/64", "outside the tailnet's /48")
        let throttle = freshThrottle()
        for _ in 0..<PasswordThrottle.allowed { _ = throttle.failed("fd7a:115c:a1e0:ab12:4843:cd96:6265:6667") }
        #expect(throttle.retryAfter("fd7a:115c:a1e0:ab12:4843:cd96:6265:6667") == 300)
        #expect(throttle.retryAfter("fd7a:115c:a1e0:ab12:4843:cd96:6265:6668") == nil, "another node")
        for host in 1...PasswordThrottle.allowed { _ = throttle.failed("2001:db8:0:3::\(host)") }
        #expect(throttle.retryAfter("2001:db8:0:3::abcd") == 300, "any other address by its /64")
    }
}
}
}
