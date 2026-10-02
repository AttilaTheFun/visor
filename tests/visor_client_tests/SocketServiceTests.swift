// The Apple socket service against a server that is not there for it: the
// channel must say so, or the client waits on it for ever and never tries
// the computer again.

import Foundation
import Network
import Synchronization
import VisorServices
import XCTest

@MainActor
final class SocketServiceTests: XCTestCase {
    /// A listener that answers every connection with one fixed reply and
    /// closes: a front whose server behind it is still starting.
    private func refusingListener(_ reply: String) async throws -> (listener: NWListener, port: UInt16) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { continuation.yield(port); continuation.finish() }
                if case .failed = state { continuation.finish() }
            }
        }
        listener.start(queue: .global())
        for await port in ready { return (listener, port) }
        throw XCTSkip("no listener")
    }

    /// The first thing the socket says, or nil if it says nothing in time.
    private func firstEvent(of service: NativeVisorSocketService, id: Int32, within seconds: Double) async -> String? {
        let waiting = Task { try? await service.next(id: id) }
        let limit = Task {
            try? await Task.sleep(for: .seconds(seconds))
            // Nothing said: closing it is what ends the wait.
            service.disconnect(id: id)
        }
        let event = await waiting.value
        limit.cancel()
        return event
    }

    func testAHandshakeThatIsRefusedIsSaid() async throws {
        let (listener, port) = try await refusingListener("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { listener.cancel() }
        let service = NativeVisorSocketService()
        let id = service.open(url: "ws://127.0.0.1:\(port)")
        let event = await firstEvent(of: service, id: id, within: 8)
        // Its own word for it, not the "close closed" of having given up.
        XCTAssertNotNil(event)
        XCTAssertNotEqual(event, "close closed", "the socket never said the handshake failed")
        XCTAssertTrue(event?.hasPrefix("error ") == true || event?.hasPrefix("close ") == true, event ?? "nothing")
    }

    /// A front that takes the connection and then says nothing at all.
    func testAHandshakeThatNeverAnswersIsSaid() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let held = HeldConnections()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            held.keep(connection)
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { continuation.yield(port); continuation.finish() }
            }
        }
        listener.start(queue: .global())
        var port: UInt16 = 0
        for await value in ready { port = value }
        defer { listener.cancel() }
        let service = NativeVisorSocketService()
        let id = service.open(url: "ws://127.0.0.1:\(port)")
        let event = await firstEvent(of: service, id: id, within: 25)
        XCTAssertNotEqual(event, "close closed", "the socket waited for ever on a handshake that never came")
    }

    func testAServerThatIsNotThereIsSaid() async throws {
        // A port nothing listens on.
        let (listener, port) = try await refusingListener("")
        listener.cancel()
        try await Task.sleep(for: .milliseconds(200))
        let service = NativeVisorSocketService()
        let id = service.open(url: "ws://127.0.0.1:\(port)")
        let event = await firstEvent(of: service, id: id, within: 8)
        XCTAssertNotEqual(event, "close closed", "the socket never said it could not connect")
        XCTAssertTrue(event?.hasPrefix("error ") == true || event?.hasPrefix("close ") == true, event ?? "nothing")
    }
}

/// Connections a listener holds open without answering.
private final class HeldConnections: Sendable {
    private let connections = Mutex<[NWConnection]>([])
    func keep(_ connection: NWConnection) { connections.withLock { $0.append(connection) } }
}
