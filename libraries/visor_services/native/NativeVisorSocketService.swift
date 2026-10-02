// The Apple implementations: URLSessionWebSocketTask behind the socket
// service (events queued per socket, handed out one at a time to `next`),
// UserDefaults behind settings. Compiled in on Apple only (the BUILD's
// select); the web page brings its own in JavaScript.

#if canImport(Darwin)
import Foundation
import Security

@MainActor
public final class NativeVisorSocketService: VisorSocketService {
    private final class Socket {
        let task: URLSessionWebSocketTask
        var events: [String] = []
        var waiter: CheckedContinuation<String, Error>?
        var closed = false
        var reader: Task<Void, Never>?
        init(task: URLSessionWebSocketTask) { self.task = task }
    }

    private var sockets: [Int32: Socket] = [:]
    private var nextID: Int32 = 1
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    public func open(url: String) -> Int32 {
        guard let target = URL(string: url) else { return -1 }
        let id = nextID
        nextID += 1
        let task = session.webSocketTask(with: target)
        let socket = Socket(task: task)
        sockets[id] = socket
        task.resume()
        // One reader per socket, on the main actor: its events are queued
        // in the order they arrived.
        socket.reader = Task { [weak self] in
            do {
                // URLSession has no "open" callback on the task itself; a
                // ping that answers means the handshake is done.
                try await Self.ping(task)
            } catch {
                self?.push(id, "error \(error.localizedDescription)")
                self?.finish(id)
                return
            }
            self?.push(id, "open")
            do {
                while true {
                    switch try await task.receive() {
                    case .string(let text): self?.push(id, "message " + text)
                    case .data(let data): self?.push(id, "message " + (String(data: data, encoding: .utf8) ?? ""))
                    @unknown default: break
                    }
                }
            } catch {
                self?.push(id, "close \(error.localizedDescription)")
                self?.finish(id)
            }
        }
        return id
    }

    private nonisolated static func ping(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    public func send(id: Int32, text: String) {
        sockets[id]?.task.send(.string(text)) { _ in }
    }

    public func disconnect(id: Int32) {
        guard let socket = sockets[id] else { return }
        socket.reader?.cancel()
        socket.task.cancel(with: .normalClosure, reason: nil)
        push(id, "close closed")
        finish(id)
    }

    public func delay(milliseconds: Int32) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }

    public func next(id: Int32) async throws -> String {
        guard let socket = sockets[id] else { throw VisorSocketGone() }
        if !socket.events.isEmpty {
            let event = socket.events.removeFirst()
            if socket.closed && socket.events.isEmpty { sockets[id] = nil }
            return event
        }
        if socket.closed {
            sockets[id] = nil
            throw VisorSocketGone()
        }
        return try await withCheckedThrowingContinuation { socket.waiter = $0 }
    }

    private func push(_ id: Int32, _ event: String) {
        guard let socket = sockets[id], !socket.closed else { return }
        if let waiter = socket.waiter {
            socket.waiter = nil
            waiter.resume(returning: event)
        } else {
            socket.events.append(event)
        }
    }

    /// No more events after what is queued; a waiting `next` is failed.
    private func finish(_ id: Int32) {
        guard let socket = sockets[id] else { return }
        socket.closed = true
        let waiter = socket.waiter
        socket.waiter = nil
        if socket.events.isEmpty { sockets[id] = nil }
        waiter?.resume(throwing: VisorSocketGone())
    }
}
#endif
