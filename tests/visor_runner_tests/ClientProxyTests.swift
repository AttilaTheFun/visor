// The Runner's client proxy (docs/co-tenancy.md): a server's clients come to
// the front's port, IPv4 or IPv6, and each connection goes on to the server
// with the bytes both ways as they come; when the client is done, the
// server hears so and its answer still comes back. A server that can't be
// reached closes the client's connection at once.

import CVisorPOSIX
import Foundation
import Synchronization
import VisorRunner
import XCTest

/// A server played here: it answers each connection with what it read,
/// upper-cased, once the client has said all it will (its end read).
private final class FakeServer: Sendable {
    let port: UInt16
    private let listener: Int32

    init?() {
        for _ in 0..<20 {
            let port = UInt16.random(in: 20000...45000)
            let socket = visor_listen(port, 0)
            if socket >= 0 {
                self.port = port
                listener = socket
                Thread.detachNewThread { [self] in serve() }
                return
            }
        }
        return nil
    }

    private func serve() {
        while true {
            let connection = visor_accept(listener)
            if connection < 0 { return }
            Thread.detachNewThread {
                var heard = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
                    if count <= 0 { break }
                    heard.append(contentsOf: buffer[0..<count])
                }
                let answer = Array(String(decoding: heard, as: UTF8.self).uppercased().utf8)
                _ = answer.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
                close(connection)
            }
        }
    }

    func stop() {
        visor_shutdown(listener)
        close(listener)
    }
}

final class ClientProxyTests: XCTestCase {
    private func front(to host: String, _ hostPort: Int) throws -> ClientProxy {
        for _ in 0..<20 {
            if let proxy = ClientProxy(front: .init(name: "co-tenant", port: Int.random(in: 20000...45000), host: host, hostPort: hostPort)) {
                proxy.start()
                return proxy
            }
        }
        throw XCTSkip("no port for the front")
    }

    /// Says `text` through the front at `address`, says it's done, and reads
    /// the answer to its end.
    private static func say(_ text: String, to address: String, port: Int) throws -> String {
        let connection = visor_connect_tcp(address, UInt16(port))
        guard connection >= 0 else { throw XCTSkip("\(address) can't be reached here") }
        defer { close(connection) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        visor_shutdown_write(connection)
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            answer.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: answer, as: UTF8.self)
    }

    func testAConnectionGoesOnToTheServerAndItsAnswerComesBack() throws {
        let server = try XCTUnwrap(FakeServer())
        defer { server.stop() }
        let proxy = try front(to: "127.0.0.1", Int(server.port))
        defer { proxy.stop() }
        XCTAssertEqual(try Self.say("hello over ipv4", to: "127.0.0.1", port: proxy.front.port), "HELLO OVER IPV4")
        // Many at once, each its own.
        let answers = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let answer = (try? ClientProxyTests.say("client \(index)", to: "127.0.0.1", port: proxy.front.port)) ?? ""
            answers.withLock { $0.append(answer) }
        }
        XCTAssertEqual(Set(answers.withLock { $0 }), Set((0..<8).map { "CLIENT \($0)" }))
    }

    func testIPv6ClientsComeToTheSamePort() throws {
        let server = try XCTUnwrap(FakeServer())
        defer { server.stop() }
        let proxy = try front(to: "127.0.0.1", Int(server.port))
        defer { proxy.stop() }
        XCTAssertEqual(try Self.say("hello over ipv6", to: "::1", port: proxy.front.port), "HELLO OVER IPV6")
    }

    func testAServerThatCantBeReachedEndsTheClientsConnection() throws {
        // A port nothing listens on: one just let go. (Not a FakeServer
        // stopped at once: its accept thread could start after the stop, on
        // the descriptor number the front's listener is given next.)
        var port = 0
        for _ in 0..<20 where port == 0 {
            let candidate = UInt16.random(in: 20000...45000)
            let socket = visor_listen(candidate, 0)
            if socket >= 0 {
                close(socket)
                port = Int(candidate)
            }
        }
        let proxy = try front(to: "127.0.0.1", port)
        defer { proxy.stop() }
        let started = Date()
        XCTAssertEqual(try Self.say("anyone?", to: "127.0.0.1", port: proxy.front.port), "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
