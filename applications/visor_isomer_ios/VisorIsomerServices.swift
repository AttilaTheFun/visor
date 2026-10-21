// The client's services, served from this native app to the client running
// as wasm, behind the bridges the client imports
// (//libraries/visor_services_ffi), whose host side swift_ffi generates
// (VisorServicesHost).
//
// Written here against Foundation as iOS 15 has it, not taken from Visor's
// Apple services (//libraries/visor_services, native/): those come
// with Visor's SSH library, which uses Synchronization's Mutex (iOS 18).
// That is the pilot's point in miniature: inside the reactor the client
// uses Mutex freely; only this shell is bound to the OS's own APIs.
//
// Not served, so the client falls back as on the web and Android: the
// message cache (kept in memory), SSH (the client tries the computer's next
// path), the keychain (the client keeps its secrets with its settings:
// UserDefaults in this pilot).

import AVFoundation
import Foundation
import Network
import Speech
import UIKit
import SwiftFFIWasmHost
import VisorServicesHost

/// The dependency table the client's `installBridgedVisorServices` reads,
/// under the bridges' keys (BridgeKey in visor_services_ffi).
func visorDependencies() -> [String: SwiftFFIDependency] {
    [
        "socket": Dependencies.socketBridge { SocketBridgeHost() },
        "http": Dependencies.httpBridge { HttpBridgeHost() },
        "settings": Dependencies.settingsBridge { SettingsBridgeHost() },
        "dictation": Dependencies.dictationBridge { DictationBridgeHost() },
        "network": Dependencies.networkBridge { NetworkBridgeHost() },
    ]
}

/// The prefix of the client's generated swift_ffi exports.
let visorFFIPrefix = "swift_ffi_visor_"

/// What the client reports as its platform to the servers it reaches (their
/// clients list shows it): which build of the shell this is, set by the app
/// before the client starts.
nonisolated(unsafe) var visorHostPlatform = "iOS (Isomer)"

/// A WebSocket per id. `next` hands out the socket's events one at a time,
/// as one line each — "open", "message <text>", "close <reason>",
/// "error <reason>" — and throws once the socket is gone (the bridge's
/// contract, as the web page's and Android's sockets keep it).
final class SocketBridgeHost: NSObject, SocketBridge, URLSessionWebSocketDelegate, @unchecked Sendable {
    private final class Socket {
        let task: URLSessionWebSocketTask
        var events: [String] = []
        var waiter: CheckedContinuation<String, Error>?
        var closed = false
        init(task: URLSessionWebSocketTask) { self.task = task }
    }

    private struct Gone: Error, CustomStringConvertible { var description: String { "socket closed" } }

    // Guards `sockets`, `ids` and every Socket's fields: URLSession calls back
    // on its own queue while the bridge is asked from the reactor's.
    private let lock = NSLock()
    private var sockets: [Int32: Socket] = [:]
    private var ids: [Int: Int32] = [:]
    private var nextID: Int32 = 1
    // As red Visor's sockets (visor's NativeVisorSocketService): no waiting
    // for connectivity, and a handshake that hasn't answered in 15 s fails,
    // so a path that doesn't answer gives way to the next.
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func open(url: String) -> Int32 {
        guard let target = URL(string: url) else { return -1 }
        let task = session.webSocketTask(with: target)
        let socket = Socket(task: task)
        lock.lock()
        let id = nextID
        nextID += 1
        sockets[id] = socket
        ids[task.taskIdentifier] = id
        lock.unlock()
        receive(socket)
        task.resume()
        return id
    }

    func send(id: Int32, text: String) {
        lock.lock()
        let socket = sockets[id]
        lock.unlock()
        socket?.task.send(.string(text)) { _ in }
    }

    func disconnect(id: Int32) {
        lock.lock()
        let socket = sockets.removeValue(forKey: id)
        if let socket { ids[socket.task.taskIdentifier] = nil }
        let waiter = socket?.waiter
        socket?.waiter = nil
        socket?.closed = true
        lock.unlock()
        socket?.task.cancel(with: .normalClosure, reason: nil)
        waiter?.resume(throwing: Gone())
    }

    func next(id: Int32) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard let socket = sockets[id] else {
                lock.unlock()
                continuation.resume(throwing: Gone())
                return
            }
            if !socket.events.isEmpty {
                let event = socket.events.removeFirst()
                if socket.closed, socket.events.isEmpty { sockets[id] = nil }
                lock.unlock()
                continuation.resume(returning: event)
            } else if socket.closed {
                sockets[id] = nil
                lock.unlock()
                continuation.resume(throwing: Gone())
            } else {
                socket.waiter = continuation
                lock.unlock()
            }
        }
    }

    func delay(milliseconds: Int32) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }

    // MARK: Events

    private func receive(_ socket: Socket) {
        socket.task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.push("message " + text, to: socket)
                self.receive(socket)
            case .success(.data(let data)):
                self.push("message " + String(decoding: data, as: UTF8.self), to: socket)
                self.receive(socket)
            case .success:
                self.receive(socket)
            case .failure(let error):
                self.push("close " + error.localizedDescription, to: socket, finishing: true)
            }
        }
    }

    private func push(_ event: String, to socket: Socket, finishing: Bool = false) {
        lock.lock()
        guard !socket.closed else { lock.unlock(); return }
        if finishing { socket.closed = true }
        if let waiter = socket.waiter {
            socket.waiter = nil
            lock.unlock()
            waiter.resume(returning: event)
        } else {
            socket.events.append(event)
            lock.unlock()
        }
    }

    private func socket(for task: URLSessionTask) -> Socket? {
        lock.lock()
        defer { lock.unlock() }
        return ids[task.taskIdentifier].flatMap { sockets[$0] }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        if let socket = socket(for: webSocketTask) { push("open", to: socket) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if let socket = socket(for: webSocketTask) {
            let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            push("close " + (text.isEmpty ? "code \(closeCode.rawValue)" : text), to: socket, finishing: true)
        }
    }

    /// Refused before it opened (an upgrade a proxy answered with 501, a
    /// server that isn't there): "error", then gone — what the client's
    /// fallback to polling waits for.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let socket = socket(for: task) else { return }
        push("error " + error.localizedDescription, to: socket)
        push("close " + error.localizedDescription, to: socket, finishing: true)
    }
}

/// One HTTP request with a bearer token: the body for a 2xx status, else a
/// throw that reads "HTTP <status>: …" across the bridge (what the client's
/// status(of:) parses; a 401 is a computer asking for its password).
final class HttpBridgeHost: HttpBridge {
    private struct Failure: Error, CustomStringConvertible {
        let status: Int
        let body: String
        var description: String { "HTTP \(status): \(body.prefix(200))" }
    }

    func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        guard let target = URL(string: url) else { throw Failure(status: 0, body: "bad url") }
        var request = URLRequest(url: target)
        request.httpMethod = method.isEmpty ? "GET" : method
        request.timeoutInterval = 30
        request.setValue("Bearer " + authorization, forHTTPHeaderField: "Authorization")
        if !body.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else { throw Failure(status: status, body: text) }
        return text
    }
}

/// The device's networks, as native Visor's (NativeVisorNetworkService):
/// each IPv4 interface's address and mask (getifaddrs), and the Network
/// framework's word when its path changes, passed on when the interfaces
/// it reports differ (not for the path the monitor reports at its start,
/// which would set every sign-in under way going again).
final class NetworkBridgeHost: NetworkBridge, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var reported: String
    /// A change not yet asked for, and the client waiting on the next.
    private var pending = false
    private var waiter: CheckedContinuation<Void, Error>?

    init() {
        reported = Self.currentInterfaces()
        monitor.pathUpdateHandler = { [weak self] _ in self?.pathUpdated() }
        monitor.start(queue: .main)
    }

    func interfaces() -> String { Self.currentInterfaces() }

    func changed() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if pending {
                pending = false
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private func pathUpdated() {
        let now = Self.currentInterfaces()
        lock.lock()
        guard now != reported else { lock.unlock(); return }
        reported = now
        let waiter = waiter
        self.waiter = nil
        if waiter == nil { pending = true }
        lock.unlock()
        waiter?.resume()
    }

    /// "address/mask" per IPv4 interface, loopback left out, sorted.
    private static func currentInterfaces() -> String {
        var lines: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return "" }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), let netmask = entry.ifa_netmask else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if value >> 24 == 127 { continue }
            lines.append(dotted(value) + "/" + dotted(mask))
        }
        return lines.sorted().joined(separator: "\n")
    }

    private static func dotted(_ value: UInt32) -> String {
        "\(value >> 24).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
    }
}

/// UserDefaults under "visor.", as Visor's own Apple settings keep them (so
/// `-visor.fixture snapshot` on the command line works here too).
final class SettingsBridgeHost: SettingsBridge {
    func get(key: String) -> String {
        // What the servers this client carries messages for call it, and
        // this build and system, which the client reports to them.
        if key == "host.deviceName" { return UIDevice.current.name }
        if key == "host.platform" { return visorHostPlatform }
        // iOS suspends the app in the background and its sockets with it.
        if key == "host.socketsDropInBackground" { return "1" }
        if key == "host.appVersion" {
            // MAJOR.MINOR.BUILD, as every app shows it (the build number is 1).
            return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        }
        return UserDefaults.standard.string(forKey: "visor." + key) ?? ""
    }
    func set(key: String, value: String) {
        if value.isEmpty { UserDefaults.standard.removeObject(forKey: "visor." + key) }
        else { UserDefaults.standard.set(value, forKey: "visor." + key) }
    }
}

/// Dictation, as native Visor's (NativeVisorDictationService): the
/// system's speech recognizer fed by the microphone through an audio engine
/// tap, the audio session taken for recording while it listens. What it
/// hears waits for the client's `next`.
final class DictationBridgeHost: DictationBridge, @unchecked Sendable {
    private struct Refused: Error, CustomStringConvertible { let description: String }
    private struct Stopped: Error, CustomStringConvertible { var description: String { "dictation stopped" } }

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// The latest of what was heard, not yet asked for.
    private var heard: String?
    private var waiter: CheckedContinuation<String, Error>?
    private var stopped = true

    func start() async throws {
        stop()
        guard await Self.speechAuthorized() else { throw Refused(description: "Speech recognition is not allowed for Visor.") }
        guard await Self.microphoneAuthorized() else { throw Refused(description: "The microphone is not allowed for Visor.") }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw Refused(description: "Speech recognition is not available.")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        let task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            self?.deliver(text)
        }
        lock.lock()
        self.engine = engine
        self.request = request
        self.task = task
        heard = nil
        stopped = false
        lock.unlock()
    }

    func next() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let text = heard {
                heard = nil
                lock.unlock()
                continuation.resume(returning: text)
            } else if stopped {
                lock.unlock()
                continuation.resume(throwing: Stopped())
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func stop() {
        lock.lock()
        let engine = engine, request = request, task = task, waiter = waiter
        self.engine = nil
        self.request = nil
        self.task = nil
        self.waiter = nil
        let wasListening = !stopped
        stopped = true
        lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        task?.finish()
        waiter?.resume(throwing: Stopped())
        if wasListening { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    private func deliver(_ text: String) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            heard = text
            lock.unlock()
        }
    }

    private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private static func microphoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
