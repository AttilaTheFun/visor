// The Apple implementations: URLSessionWebSocketTask behind the socket
// service (events queued per socket, handed out one at a time to `next`),
// UserDefaults behind settings. Compiled in on Apple only (the BUILD's
// select); the web page brings its own in JavaScript.

#if canImport(Darwin)
import Foundation

public final class NativeVisorSocketService: VisorSocketService, @unchecked Sendable {
    private final class Socket {
        let task: URLSessionWebSocketTask
        var events: [String] = []
        var waiter: CheckedContinuation<String, Error>?
        var closed = false
        init(task: URLSessionWebSocketTask) { self.task = task }
    }

    private var sockets: [Int32: Socket] = [:]
    private var nextID: Int32 = 1
    private let lock = NSLock()
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    public func open(url: String) -> Int32 {
        guard let target = URL(string: url) else { return -1 }
        lock.lock()
        let id = nextID
        nextID += 1
        let task = session.webSocketTask(with: target)
        let socket = Socket(task: task)
        sockets[id] = socket
        lock.unlock()
        task.resume()
        // URLSession has no "open" callback on the task itself; a ping that
        // answers means the handshake is done.
        task.sendPing { [weak self] error in
            if let error { self?.push(id, "error \(error.localizedDescription)"); self?.finish(id) }
            else { self?.push(id, "open") }
        }
        receive(id, task)
        return id
    }

    private func receive(_ id: Int32, _ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.push(id, "message " + text)
                case .data(let data): self.push(id, "message " + (String(data: data, encoding: .utf8) ?? ""))
                @unknown default: break
                }
                self.receive(id, task)
            case .failure(let error):
                self.push(id, "close \(error.localizedDescription)")
                self.finish(id)
            }
        }
    }

    public func send(id: Int32, text: String) {
        lock.lock(); let socket = sockets[id]; lock.unlock()
        socket?.task.send(.string(text)) { _ in }
    }

    public func disconnect(id: Int32) {
        lock.lock(); let socket = sockets[id]; lock.unlock()
        socket?.task.cancel(with: .normalClosure, reason: nil)
        push(id, "close closed")
        finish(id)
    }

    public func delay(milliseconds: Int32) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }

    public func next(id: Int32) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard let socket = sockets[id] else {
                lock.unlock()
                continuation.resume(throwing: VisorSocketGone())
                return
            }
            if !socket.events.isEmpty {
                let event = socket.events.removeFirst()
                if socket.closed && socket.events.isEmpty { sockets[id] = nil }
                lock.unlock()
                continuation.resume(returning: event)
            } else if socket.closed {
                sockets[id] = nil
                lock.unlock()
                continuation.resume(throwing: VisorSocketGone())
            } else {
                socket.waiter = continuation
                lock.unlock()
            }
        }
    }

    private func push(_ id: Int32, _ event: String) {
        lock.lock()
        guard let socket = sockets[id], !socket.closed else { lock.unlock(); return }
        if let waiter = socket.waiter {
            socket.waiter = nil
            lock.unlock()
            waiter.resume(returning: event)
        } else {
            socket.events.append(event)
            lock.unlock()
        }
    }

    /// No more events after what is queued; a waiting `next` is failed.
    private func finish(_ id: Int32) {
        lock.lock()
        guard let socket = sockets[id] else { lock.unlock(); return }
        socket.closed = true
        let waiter = socket.waiter
        socket.waiter = nil
        if socket.events.isEmpty { sockets[id] = nil }
        lock.unlock()
        waiter?.resume(throwing: VisorSocketGone())
    }
}

public struct VisorSocketGone: Error {}

public struct VisorHTTPFailure: Error, CustomStringConvertible {
    public let status: Int
    public let body: String
    public var description: String { "HTTP \(status): \(body.prefix(200))" }
}

public final class NativeVisorHTTPService: VisorHTTPService {
    /// Many requests at once: every open transcript holds a long poll, and
    /// a send must not wait behind them. The shared session caps a host at
    /// six connections, which a handful of subscribed sessions exhaust.
    private let httpSession: URLSession = {
        let http = URLSessionConfiguration.default
        http.waitsForConnectivity = false
        http.httpMaximumConnectionsPerHost = 16
        // A transcript long poll is held on the computer for a while; the
        // per-request timeout in `request` leaves room, and the resource
        // timeout must not cut it short.
        http.timeoutIntervalForRequest = 60
        http.timeoutIntervalForResource = 120
        return URLSession(configuration: http)
    }()

    public init() {}

    public func status(of error: Error) -> Int? { (error as? VisorHTTPFailure)?.status }

    public func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        guard let target = URL(string: url) else { throw VisorHTTPFailure(status: 0, body: "bad url") }
        var request = URLRequest(url: target)
        request.httpMethod = method
        // A transcript sync is held on the computer for a while before it
        // answers; the limit leaves room for that and the round trip.
        request.timeoutInterval = 45
        request.setValue("Bearer " + authorization, forHTTPHeaderField: "Authorization")
        if !body.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        let (data, response) = try await httpSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else { throw VisorHTTPFailure(status: status, body: text) }
        return text
    }
}

public final class NativeVisorSettingsService: VisorSettingsService {
    public init() {}

    public func get(key: String) -> String {
        UserDefaults.standard.string(forKey: "visor." + key) ?? ""
    }

    public func set(key: String, value: String) {
        if value.isEmpty { UserDefaults.standard.removeObject(forKey: "visor." + key) }
        else { UserDefaults.standard.set(value, forKey: "visor." + key) }
    }
}
#endif
