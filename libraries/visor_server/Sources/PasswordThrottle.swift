// How many wrong passwords an address may show: a few a minute, then none
// for five minutes. The password is four words of 24 (about 18 bits), in
// reach of a guesser on the network that nothing slows. Kept per address,
// never for the server as a whole, so a stranger on the network can't
// shut its owner out: an IPv6 address by its /64, which one device holds
// whole (it picks addresses within it as it likes), but a tailnet's by
// itself (the tailnet's nodes share one /64). This computer (loopback,
// where a front it sits behind comes from too, but for the client
// `tailscale serve` names: ForwardedFor) and the socket file are never
// counted, nor a connection the system gives no address.

import Foundation
import VisorSystem

struct PasswordThrottle {
    /// The wrong passwords an address may show within `window`: the last
    /// of them locks it out.
    static let allowed = 5
    /// Seconds over which they are counted, from the first.
    static let window: TimeInterval = 60
    /// Seconds an address is locked out for: nothing it shows is taken.
    static let lockout: TimeInterval = 5 * 60
    /// How many addresses are kept at once; past it, the one heard from
    /// longest ago is forgotten.
    static let tracked = 1024

    /// One address's wrong passwords.
    private struct Count {
        var failures: Int
        /// When the first of them came.
        var since: Date
        /// When it may show one again, while it's locked out.
        var lockedUntil: Date?
        /// When it was last heard from, for which to forget first.
        var heard: Date
    }

    private var counts: [String: Count] = [:]
    /// The time now: the system's, or a test's.
    private let clock: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        clock = now
    }

    /// How many addresses are kept now.
    var trackedCount: Int { counts.count }

    /// Seconds until `address` may show a password again, while it is
    /// locked out; nil when it may now.
    func retryAfter(_ address: String?) -> Int? {
        guard let key = Self.key(address), let until = counts[key]?.lockedUntil else { return nil }
        let left = until.timeIntervalSince(clock())
        return left > 0 ? Int(left.rounded(.up)) : nil
    }

    /// A wrong password from `address`, counted: true when it is the one
    /// that locks the address out (once a lockout, for the log).
    mutating func failed(_ address: String?) -> Bool {
        guard let key = Self.key(address) else { return false }
        let now = clock()
        var count = counts[key] ?? Count(failures: 0, since: now, heard: now)
        if let until = count.lockedUntil, until > now { return false }
        // A lockout over, or a window gone by: counted afresh.
        if count.lockedUntil != nil || now.timeIntervalSince(count.since) >= Self.window {
            count = Count(failures: 0, since: now, heard: now)
        }
        count.failures += 1
        count.heard = now
        let locks = count.failures >= Self.allowed
        if locks { count.lockedUntil = now.addingTimeInterval(Self.lockout) }
        keep(count, for: key, now: now)
        return locks
    }

    /// A password, token or admin token taken from `address`: what it got
    /// wrong before is forgotten.
    mutating func succeeded(_ address: String?) {
        guard let key = Self.key(address) else { return }
        counts[key] = nil
    }

    /// `count` kept for `key`; a new address past `tracked` first makes
    /// room, the counts that are over going before the oldest.
    private mutating func keep(_ count: Count, for key: String, now: Date) {
        if counts[key] == nil, counts.count >= Self.tracked {
            counts = counts.filter { _, kept in
                kept.lockedUntil.map { $0 > now } ?? (now.timeIntervalSince(kept.since) < Self.window)
            }
            while counts.count >= Self.tracked, let oldest = counts.min(by: { $0.value.heard < $1.value.heard })?.key {
                counts[oldest] = nil
            }
        }
        counts[key] = count
    }

    /// What an address is counted under: an IPv4 address as it is, an
    /// IPv6 one by its /64 (`2001:db8:0:1::/64`) but a tailnet's whole
    /// (`fd7a:115c:a1e0:ab12:4843:cd96:6265:6667`), one of IPv4 in IPv6
    /// (`::ffff:192.168.1.5`) as the IPv4 address. Nil for what is never
    /// counted: none, loopback.
    static func key(_ address: String?) -> String? {
        guard var address = address?.trimmingCharacters(in: .whitespaces), !address.isEmpty else { return nil }
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        // An address may carry its interface ("fe80::1%en0"): the address alone.
        address = String(address.split(separator: "%", omittingEmptySubsequences: false).first ?? "").lowercased()
        guard address.contains(":") else { return address.isEmpty || NetworkAddress.isLoopback(address) ? nil : address }
        guard let groups = groups(ipv6: address) else { return address }
        if groups[0..<5].allSatisfy({ $0 == 0 }), groups[5] == 0xffff {
            let v4 = [groups[6] >> 8, groups[6] & 0xff, groups[7] >> 8, groups[7] & 0xff].map { String($0) }.joined(separator: ".")
            return NetworkAddress.isLoopback(v4) ? nil : v4
        }
        if groups[0..<7].allSatisfy({ $0 == 0 }), groups[7] == 1 { return nil }
        // A tailnet's node is given its one address by Tailscale's
        // coordination server, and picks no other; its nodes all share a
        // /64, which would count the whole tailnet as one.
        if isTailnet(groups) { return groups.map { String($0, radix: 16) }.joined(separator: ":") }
        return groups[0..<4].map { String($0, radix: 16) }.joined(separator: ":") + "::/64"
    }

    /// Whether an IPv6 address (its eight groups) is a tailnet node's:
    /// Tailscale's fd7a:115c:a1e0::/48 (net/tsaddr's TailscaleULARange).
    static func isTailnet(_ groups: [UInt16]) -> Bool {
        groups.count == 8 && groups[0] == 0xfd7a && groups[1] == 0x115c && groups[2] == 0xa1e0
    }

    /// An IPv6 address's eight groups, `::` filled and an IPv4 address at
    /// its end taken as the last two; nil when it isn't one.
    static func groups(ipv6 text: String) -> [UInt16]? {
        var head = Substring(text)
        var tail: [UInt16] = []
        if let colon = head.lastIndex(of: ":"), head[head.index(after: colon)...].contains(".") {
            let parts = head[head.index(after: colon)...].split(separator: ".", omittingEmptySubsequences: false)
            let bytes = parts.compactMap { $0.allSatisfy(\.isNumber) ? UInt8($0) : nil }
            guard parts.count == 4, bytes.count == 4 else { return nil }
            tail = [UInt16(bytes[0]) << 8 | UInt16(bytes[1]), UInt16(bytes[2]) << 8 | UInt16(bytes[3])]
            head = head[...colon]
            if !head.hasSuffix("::") { head = head.dropLast() }
        }
        let halves = head.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func read(_ part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            let words = part.split(separator: ":", omittingEmptySubsequences: false)
            let values = words.compactMap { (1...4).contains($0.count) && $0.allSatisfy(\.isHexDigit) ? UInt16($0, radix: 16) : nil }
            return values.count == words.count ? values : nil
        }
        guard let first = read(halves[0]), let last = halves.count == 2 ? read(halves[1]) : [] else { return nil }
        let known = first.count + last.count + tail.count
        if halves.count == 2 {
            guard known <= 7 else { return nil }
            return first + Array(repeating: 0, count: 8 - known) + last + tail
        }
        return known == 8 ? first + tail : nil
    }
}
