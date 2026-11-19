// The relay's header (PROXY protocol v2): read back as written, its TLVs by
// type; a container let in only with the relay's own token, compared whole;
// read from a stream exactly, leaving what follows; and what isn't one, or
// is cut short, refused. Moved from MultiPass's tests (Logan, 2026-11-14).

import Foundation
@testable import VisorAgentProxy
import XCTest

final class ProxyProtocolHeaderTests: XCTestCase {
    func testARelayedHeaderReadsBackWithItsLeaseAndToken() throws {
        let header = ProxyProtocolHeader.relayed(lease: "lease-42", relayToken: "relay-secret")
        let bytes = header.encoded()
        let (read, length) = try ProxyProtocolHeader.parse(bytes + Array("GET / HTTP/1.1\r\n".utf8))
        XCTAssertEqual(read, header)
        XCTAssertEqual(length, bytes.count, "what follows isn't the header's")
        XCTAssertEqual(read.leaseID, "lease-42")
    }

    func testAContainerIsLetInOnlyWithTheRelaysOwnToken() {
        let header = ProxyProtocolHeader.relayed(lease: "lease-42", relayToken: "relay-secret")
        XCTAssertEqual(header.admittedLease(relayToken: "relay-secret"), "lease-42")
        XCTAssertNil(header.admittedLease(relayToken: "relay-secreT"))
        XCTAssertNil(header.admittedLease(relayToken: "relay-secret-longer"))
        XCTAssertNil(header.admittedLease(relayToken: ""), "no relay set up: nothing let in")
        XCTAssertNil(ProxyProtocolHeader(command: .proxy, tlvs: [ProxyProtocolHeader.leaseIDType: Array("x".utf8)])
            .admittedLease(relayToken: "relay-secret"), "no token")
        var local = header
        local.command = .local
        XCTAssertNil(local.admittedLease(relayToken: "relay-secret"), "the relay's own connection is no container's")
    }

    /// NCH's review of #414: the lease id goes into log lines and a
    /// forward's header, so only letters, digits and hyphens, 1 to 64.
    func testOnlyALeaseIDOfLettersDigitsAndHyphensIsLetIn() {
        XCTAssertEqual(ProxyProtocolHeader.relayed(lease: "Lease-42-ab", relayToken: "relay-secret").admittedLease(relayToken: "relay-secret"),
                       "Lease-42-ab")
        let long = String(repeating: "a", count: 64)
        XCTAssertEqual(ProxyProtocolHeader.relayed(lease: long, relayToken: "t").admittedLease(relayToken: "t"), long)
        for bad in ["", "lease\r\nX-Injected: 1", "lease 42", "lease_42", "lease/42", "l\u{e9}ase", String(repeating: "a", count: 65)] {
            let header = ProxyProtocolHeader.relayed(lease: bad, relayToken: "relay-secret")
            XCTAssertTrue(header.carriesRelayToken("relay-secret"))
            XCTAssertNil(header.admittedLease(relayToken: "relay-secret"), bad)
        }
    }

    func testAddressesAreSkippedByFamilyBeforeTheTLVs() throws {
        // TCP over IPv4: 12 bytes of addresses and ports, then a TLV.
        let addresses: [UInt8] = [10, 0, 0, 2, 10, 0, 0, 1, 0x1F, 0x90, 0x00, 0x50]
        let header = ProxyProtocolHeader(command: .proxy, family: 0x11, addresses: addresses,
                                         tlvs: [ProxyProtocolHeader.leaseIDType: Array("lease-7".utf8)])
        let read = try ProxyProtocolHeader.parse(header.encoded()).header
        XCTAssertEqual(read.addresses, addresses)
        XCTAssertEqual(read.leaseID, "lease-7")
    }

    func testWhatIsntAHeaderOrIsCutShortIsRefused() {
        XCTAssertThrowsError(try ProxyProtocolHeader.parse(Array("GET / HTTP/1.1\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? ProxyProtocolHeader.Problem, .notProxyProtocol)
        }
        let bytes = ProxyProtocolHeader.relayed(lease: "l", relayToken: "t").encoded()
        XCTAssertThrowsError(try ProxyProtocolHeader.parse(Array(bytes.dropLast()))) {
            XCTAssertEqual($0 as? ProxyProtocolHeader.Problem, .truncated)
        }
        var version1 = bytes
        version1[12] = 0x11
        XCTAssertThrowsError(try ProxyProtocolHeader.parse(version1)) {
            XCTAssertEqual($0 as? ProxyProtocolHeader.Problem, .unsupportedVersion(1))
        }
        // A TLV that says it's longer than the header.
        var badTLV = ProxyProtocolHeader(command: .proxy).encoded()
        badTLV += [0xE1, 0x00, 0x09, 0x41]
        badTLV[15] = 4
        XCTAssertThrowsError(try ProxyProtocolHeader.parse(badTLV)) {
            XCTAssertEqual($0 as? ProxyProtocolHeader.Problem, .badTLV)
        }
    }

    func testAStreamIsReadExactlyToTheHeadersEnd() throws {
        var pipes: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipes), 0)
        defer { close(pipes[0]) }
        let header = ProxyProtocolHeader.relayed(lease: "lease-9", relayToken: "relay-secret")
        let following = Array("CONNECT github.com:443 HTTP/1.1\r\n\r\n".utf8)
        let sent = header.encoded() + following
        sent.withUnsafeBytes { _ = write(pipes[1], $0.baseAddress!, sent.count) }
        close(pipes[1])
        XCTAssertEqual(try ProxyProtocolHeader.read(from: pipes[0]), header)
        var rest = [UInt8](repeating: 0, count: 256)
        let count = rest.withUnsafeMutableBytes { read(pipes[0], $0.baseAddress!, 256) }
        XCTAssertEqual(Array(rest.prefix(count)), following, "the container's own bytes, untouched")
    }

    func testAStreamThatEndsEarlyIsTruncated() {
        var pipes: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipes), 0)
        defer { close(pipes[0]) }
        let bytes = Array(ProxyProtocolHeader.relayed(lease: "l", relayToken: "t").encoded().prefix(20))
        bytes.withUnsafeBytes { _ = write(pipes[1], $0.baseAddress!, bytes.count) }
        close(pipes[1])
        XCTAssertThrowsError(try ProxyProtocolHeader.read(from: pipes[0])) {
            XCTAssertEqual($0 as? ProxyProtocolHeader.Problem, .truncated)
        }
    }
}
