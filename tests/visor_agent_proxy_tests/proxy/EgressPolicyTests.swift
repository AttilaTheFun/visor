// The egress policy (NCH's review of #414): never this Mac, by any of its
// own interfaces' addresses or however IPv6 carries one (Teredo's and local
// NAT64's IPv4 too, phase 2); the LAN's and the tailnet's private ranges
// refused unless `egressAllow` lists them, a destination listed by name
// within its pin when it has one; the internet allowed.

import CAgentProxyPOSIX
import Foundation
@testable import VisorAgentProxy
import XCTest

final class EgressPolicyTests: XCTestCase {
    /// Every address, private ranges and all, listed.
    private let everything = EgressPolicy(allow: ["0.0.0.0/0", "::/0"])

    /// This computer's interfaces' addresses, as the system says now.
    private func ownAddresses() -> [String] {
        var buffer = [CChar](repeating: 0, count: 16 << 10)
        guard agent_proxy_interface_addresses(&buffer, buffer.count) >= 0 else { return [] }
        return String(cString: buffer).split(separator: "\n").map(String.init)
    }

    func testTheInternetIsAllowed() {
        let policy = EgressPolicy()
        for address in ["1.1.1.1", "140.82.112.3", "172.32.0.1", "100.128.0.1", "192.169.0.1", "2606:4700::1111", "64:ff9b::101:101",
                        "2002:101:101::1"] {
            XCTAssertTrue(policy.allows(address: address), address)
        }
    }

    func testThisComputersOwnInterfacesAreRefusedWhateverIsListed() throws {
        let own = ownAddresses()
        XCTAssertFalse(own.isEmpty, "the system lists this computer's addresses")
        for address in own {
            XCTAssertFalse(everything.allows(address: address, listed: true), "\(address) is this computer's")
        }
        for address in ["127.0.0.1", "127.9.9.9", "0.0.0.0", "169.254.169.254", "224.0.0.1", "255.255.255.255", "::", "::1",
                        "fe80::1", "ff02::1"] {
            XCTAssertFalse(everything.allows(address: address, listed: true), address)
        }
    }

    /// A tunnel to one of this computer's own non-loopback addresses (the
    /// LAN's or the tailnet's, on the Mac), through the relay: refused,
    /// though every range is allowed.
    func testATunnelToThisComputersOwnAddressIsRefused() throws {
        guard let own = ownAddresses().first(where: { !$0.hasPrefix("127.") && $0 != "::1" && !$0.lowercased().hasPrefix("fe80") }) else {
            throw XCTSkip("no address but loopback here")
        }
        let listener = (0..<20).lazy.compactMap { _ -> (Int32, UInt16)? in
            let port = UInt16.random(in: 20000...45000)
            let socket = own.contains(":") ? agent_proxy_listen6(port) : agent_proxy_listen(port, 1)
            return socket >= 0 ? (socket, port) : nil
        }.first
        guard let listener else { throw XCTSkip("no port to listen on") }
        let (socket, serverPort) = listener
        defer { close(socket) }
        let proxy = EgressProxy(policy: everything, log: { _ in })
        let relay = try XCTUnwrap((0..<20).lazy.compactMap { _ -> (RelayListener, Int)? in
            let port = Int.random(in: 20000...45000)
            return RelayListener(port: port, relayToken: { "relay-secret" }, proxy: proxy, log: { _ in }).map { ($0, port) }
        }.first)
        relay.0.start()
        defer { relay.0.stop() }
        XCTAssertEqual(everything.connect(.init(host: own, port: serverPort)), -1)
        XCTAssertEqual(errno, EACCES)
        let connection = agent_proxy_connect_tcp("127.0.0.1", UInt16(relay.1))
        XCTAssertGreaterThanOrEqual(connection, 0)
        defer { close(connection) }
        let target = own.contains(":") ? "[\(own)]" : own
        let bytes = ProxyProtocolHeader.relayed(lease: "lease-1", relayToken: "relay-secret").encoded()
            + Array("CONNECT \(target):\(serverPort) HTTP/1.1\r\n\r\n".utf8)
        _ = bytes.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
        let answer = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 403 "), "\(own): \(answer)")
    }

    func testEachPrivateRangeIsRefusedByDefaultAndAllowedWhenListed() {
        let cases: [(address: String, range: String)] = [
            ("10.1.2.3", "10.0.0.0/8"),
            ("172.16.5.5", "172.16.0.0/12"),
            ("172.31.255.1", "172.16.0.0/12"),
            ("192.168.1.20", "192.168.0.0/16"),
            ("100.73.57.115", "100.64.0.0/10"),
            ("100.100.100.100", "100.64.0.0/10"),
            ("fd7a:115c:a1e0::1", "fd7a:115c:a1e0::/48"),
            ("fc00::1", "fc00::/7"),
        ]
        for (address, range) in cases {
            XCTAssertFalse(EgressPolicy().allows(address: address), "\(address) refused by default")
            XCTAssertTrue(EgressPolicy(allow: [range]).allows(address: address), "\(address) allowed by \(range)")
            XCTAssertTrue(EgressPolicy(allow: [address]).allows(address: address), "\(address) allowed by itself")
            XCTAssertTrue(EgressPolicy().allows(address: address, listed: true), "\(address) allowed for a listed destination")
        }
        XCTAssertFalse(EgressPolicy(allow: ["10.0.0.0/16"]).allows(address: "10.1.2.3"), "outside the range listed")
        XCTAssertFalse(EgressPolicy(allow: ["192.168.1.0/24"]).allows(address: "192.168.2.1"))
        XCTAssertTrue(EgressPolicy(allow: ["192.168.1.0/24"]).allows(address: "192.168.1.200"))
    }

    /// IPv4 carried in IPv6 is judged by the IPv4 it carries: mapped,
    /// compatible, NAT64 and 6to4 alike.
    func testTunnelledIPv6FormsAreJudgedByTheirIPv4() {
        for address in ["::ffff:127.0.0.1", "::127.0.0.1", "64:ff9b::7f00:1", "2002:7f00:1::1", "::ffff:169.254.169.254",
                        "64:ff9b::a9fe:a9fe", "2002:a9fe:a9fe::"] {
            XCTAssertFalse(everything.allows(address: address, listed: true), "\(address): never")
        }
        for address in ["::ffff:10.0.0.1", "::10.0.0.1", "64:ff9b::a00:1", "2002:c0a8:101::1", "64:ff9b::6449:3973"] {
            XCTAssertFalse(EgressPolicy().allows(address: address), "\(address): private, refused by default")
        }
        XCTAssertTrue(EgressPolicy(allow: ["10.0.0.0/8"]).allows(address: "64:ff9b::a00:1"), "listed by the IPv4 it carries")
        for own in ownAddresses() where !own.contains(":") && !own.hasPrefix("127.") {
            XCTAssertFalse(everything.allows(address: "::ffff:\(own)", listed: true), "this computer's \(own), mapped")
            XCTAssertFalse(everything.allows(address: "::\(own)", listed: true), "this computer's \(own), compatible")
        }
    }

    func testTheAllowlistTakesCIDRsAddressesAndDestinations() {
        let policy = EgressPolicy(allow: ["10.0.0.0/8", " 192.168.1.20 ", "fd7a:115c:a1e0::/48", "NAS.local:443", "[fd7a::1]:22",
                                          "nonsense", "10.0.0.0/33", "nas.local"])
        XCTAssertEqual(policy.ranges, ["10.0.0.0/8", "192.168.1.20", "fd7a:115c:a1e0::/48"])
        XCTAssertEqual(policy.destinations, ["nas.local:443", "[fd7a::1]:22"])
        XCTAssertEqual(policy.rejected, ["nonsense", "10.0.0.0/33", "nas.local"])
        XCTAssertTrue(policy.lists(.init(host: "nas.LOCAL", port: 443)))
        XCTAssertFalse(policy.lists(.init(host: "nas.local", port: 80)))
        XCTAssertTrue(policy.lists(.init(host: "fd7a::1", port: 22)))
    }

    /// Teredo (2001::/32) carries two IPv4 addresses: its server's, and its
    /// client's, each bit inverted. Each is judged; either refused refuses it.
    func testTeredoIsJudgedByItsServersAndItsClientsIPv4() {
        // Server 65.54.227.120, client 192.0.2.45 (obfuscated 3fff:fdd2): RFC 4380's example, the internet's.
        XCTAssertTrue(EgressPolicy().allows(address: "2001:0:4136:e378:8000:63bf:3fff:fdd2"))
        // Its client 127.0.0.1 (obfuscated 80ff:fffe), its server 127.0.0.1, or 169.254.169.254: never.
        for address in ["2001:0:808:808::80ff:fffe", "2001:0:7f00:1::fefe:fefe", "2001:0:a9fe:a9fe::fefe:fefe", "2001:0:808:808::5601:5601"] {
            XCTAssertFalse(everything.allows(address: address, listed: true), "\(address): never")
        }
        // A private client (10.0.0.1, obfuscated f5ff:fffe): refused unless its range is listed.
        XCTAssertFalse(EgressPolicy().allows(address: "2001:0:808:808::f5ff:fffe"))
        XCTAssertTrue(EgressPolicy(allow: ["10.0.0.0/8"]).allows(address: "2001:0:808:808::f5ff:fffe"))
        // This computer's own IPv4, as either.
        for own in ownAddresses() where !own.contains(":") && !own.hasPrefix("127.") {
            let parts = own.split(separator: ".").compactMap { UInt8($0) }
            guard parts.count == 4 else { continue }
            func groups(_ b: [UInt8]) -> String {
                String(Int(b[0]) << 8 | Int(b[1]), radix: 16) + ":" + String(Int(b[2]) << 8 | Int(b[3]), radix: 16)
            }
            let server = groups(parts), client = groups(parts.map { ~$0 })
            XCTAssertFalse(everything.allows(address: "2001:0:\(server)::fefe:fefe", listed: true), "this computer's \(own), Teredo's server")
            XCTAssertFalse(everything.allows(address: "2001:0:808:808::\(client)", listed: true), "this computer's \(own), Teredo's client")
        }
    }

    /// 64:ff9b:1::/48, NAT64 for local use (RFC 8215): its IPv4 where a
    /// translator's prefix puts it, after a /96 or a /48, each judged.
    func testLocalUseNAT64IsJudgedByItsIPv4() {
        XCTAssertTrue(EgressPolicy().allows(address: "64:ff9b:1::808:808"), "8.8.8.8 after a /96")
        XCTAssertTrue(EgressPolicy().allows(address: "64:ff9b:1:808:8:800::"), "8.8.8.8 after a /48")
        for address in ["64:ff9b:1::7f00:1", "64:ff9b:1:7f00:0:100::", "64:ff9b:1::a9fe:a9fe", "64:ff9b:1::",
                        "64:ff9b:1:808:8:800:7f00:1"] {
            XCTAssertFalse(everything.allows(address: address, listed: true), "\(address): never")
        }
        XCTAssertFalse(EgressPolicy().allows(address: "64:ff9b:1::a00:1"), "10.0.0.1: private, refused by default")
        XCTAssertTrue(EgressPolicy(allow: ["10.0.0.0/8"]).allows(address: "64:ff9b:1::a00:1"), "listed by the IPv4 it carries")
        for own in ownAddresses() where !own.contains(":") && !own.hasPrefix("127.") {
            XCTAssertFalse(everything.allows(address: "64:ff9b:1::\(own)", listed: true), "this computer's \(own)")
        }
    }

    /// A destination listed by name may carry a pin (`host:port@CIDR`): what
    /// it resolves to must fall within it, public or private, so a name
    /// rebound elsewhere reaches nothing.
    func testAPinnedDestinationReachesOnlyItsPin() {
        let policy = EgressPolicy(allow: ["nas.local:443@192.168.1.20", "box.local:22@192.168.1.0/24", "[fd7a::1]:22@fd7a:115c:a1e0::/48",
                                          "other.local:80", "both.local:80", "both.local:80@10.1.0.0/16", "bad.local:1@nonsense",
                                          "x.local:1@10.0.0.0/33", "@10.0.0.0/8"])
        XCTAssertEqual(policy.destinations, ["nas.local:443", "box.local:22", "[fd7a::1]:22", "other.local:80", "both.local:80"])
        XCTAssertEqual(policy.pins, ["nas.local:443": ["192.168.1.20"], "box.local:22": ["192.168.1.0/24"],
                                    "[fd7a::1]:22": ["fd7a:115c:a1e0::/48"], "both.local:80": ["10.1.0.0/16"]])
        XCTAssertEqual(policy.rejected, ["bad.local:1@nonsense", "x.local:1@10.0.0.0/33", "@10.0.0.0/8"])
        let nas = EgressProxy.Destination(host: "NAS.local", port: 443)
        XCTAssertTrue(policy.allows(address: "192.168.1.20", for: nas))
        XCTAssertFalse(policy.allows(address: "192.168.1.21", for: nas), "rebound within the LAN")
        XCTAssertFalse(policy.allows(address: "8.8.8.8", for: nas), "rebound to the internet")
        XCTAssertFalse(policy.allows(address: "127.0.0.1", for: nas))
        let box = EgressProxy.Destination(host: "box.local", port: 22)
        XCTAssertTrue(policy.allows(address: "192.168.1.77", for: box))
        XCTAssertFalse(policy.allows(address: "192.168.2.1", for: box))
        XCTAssertTrue(policy.allows(address: "fd7a:115c:a1e0::9", for: .init(host: "fd7a::1", port: 22)))
        XCTAssertFalse(policy.allows(address: "fd7a:115c:a1e1::9", for: .init(host: "fd7a::1", port: 22)))
        // Listed without a pin: any private address; listed with one too: pinned.
        XCTAssertTrue(policy.allows(address: "192.168.5.5", for: .init(host: "other.local", port: 80)))
        XCTAssertFalse(policy.allows(address: "192.168.5.5", for: .init(host: "both.local", port: 80)))
        XCTAssertTrue(policy.allows(address: "10.1.2.3", for: .init(host: "both.local", port: 80)))
        // Not listed: the internet alone, as ever.
        XCTAssertFalse(policy.allows(address: "192.168.1.20", for: .init(host: "nas.local", port: 80)))
        XCTAssertTrue(policy.allows(address: "8.8.8.8", for: .init(host: "nas.local", port: 80)))
        // A connection: refused before anything is sent when it resolves outside its pin.
        let literal = EgressPolicy(allow: ["192.168.1.21:443@192.168.1.20"])
        XCTAssertEqual(literal.connect(.init(host: "192.168.1.21", port: 443)), -1)
        XCTAssertEqual(errno, EACCES)
    }

    /// A private literal is refused before anything is sent its way, and
    /// logged as refused.
    func testAPrivateAddressIsRefusedThroughTheRelay() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("egress-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let egress = EgressLog(file: folder.appendingPathComponent("egress.log"))
        let proxy = EgressProxy(egress: egress, log: { _ in })
        let relay = try XCTUnwrap((0..<20).lazy.compactMap { _ -> (RelayListener, Int)? in
            let port = Int.random(in: 20000...45000)
            return RelayListener(port: port, relayToken: { "relay-secret" }, proxy: proxy, log: { _ in }).map { ($0, port) }
        }.first)
        relay.0.start()
        defer { relay.0.stop() }
        for target in ["10.255.255.1:22", "100.73.57.115:7480", "[fd7a:115c:a1e0::1]:7434", "192.168.1.1:80"] {
            let connection = agent_proxy_connect_tcp("127.0.0.1", UInt16(relay.1))
            XCTAssertGreaterThanOrEqual(connection, 0)
            let bytes = ProxyProtocolHeader.relayed(lease: "lease-1", relayToken: "relay-secret").encoded()
                + Array("CONNECT \(target) HTTP/1.1\r\n\r\n".utf8)
            _ = bytes.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
            close(connection)
            let answer = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
            XCTAssertTrue(answer.hasPrefix("HTTP/1.1 403 "), "\(target): \(answer)")
        }
        XCTAssertEqual(egress.entries().map(\.outcome), [.refused, .refused, .refused, .refused])
    }
}
