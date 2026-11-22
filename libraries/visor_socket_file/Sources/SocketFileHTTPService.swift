// The REST side of a server at its socket file (SocketFileURL): one request
// on a connection of its own, its answer read until the server closes it,
// as it does after each (HTTPServer). What the host's own HTTP service is
// for a URL, this is for `http+unix://…`.

import Foundation
import VisorProtocol
import VisorServices
import VisorSystem

/// How a connection to a socket file is made: the host's
/// (POSIXUnixSocket.connect); nil when nothing listens there.
public typealias SocketFileConnect = @Sendable @MainActor (String) async -> (any ByteStream)?

public final class SocketFileHTTPService: VisorHTTPService {
    private let connect: SocketFileConnect
    /// Headers every request carries besides its own (Visor.app's key).
    private let extraHeaders: @Sendable () -> [String: String]
    /// How long an answer may take: a transcript's long poll is held on the
    /// server for a while, as over the network.
    private let timeout: Duration

    public init(connect: @escaping SocketFileConnect, headers: @escaping @Sendable () -> [String: String] = { [:] },
                timeout: Duration = .seconds(60)) {
        self.connect = connect
        extraHeaders = headers
        self.timeout = timeout
    }

    public func status(of error: Error) -> Int? { (error as? SocketFileHTTPFailure)?.status }
    public func body(of error: Error) -> String? { (error as? SocketFileHTTPFailure)?.body }

    public func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        try await request(method: method, url: url, body: body, headers: authorization.isEmpty ? [:] : ["Authorization": "Bearer " + authorization])
    }

    /// Refused (401, 403) with headers of this service's own that have
    /// changed since (the app key, kept again by the server as it refused:
    /// AppKeyKeeper), it's asked once more with the new ones.
    public func request(method: String, url: String, body: String, headers: [String: String]) async throws -> String {
        guard let (socket, path) = SocketFileURL.split(url) else { throw SocketFileHTTPFailure(status: 0, body: "not a socket file's URL: \(url)") }
        let shown = extraHeaders()
        let answer = try await send(method: method, path: path, body: body, headers: headers, extra: shown, socket: socket)
        if answer.status == 401 || answer.status == 403 {
            let now = extraHeaders()
            if now != shown {
                let again = try await send(method: method, path: path, body: body, headers: headers, extra: now, socket: socket)
                guard (200..<300).contains(again.status) else { throw SocketFileHTTPFailure(status: again.status, body: again.body) }
                return again.body
            }
        }
        guard (200..<300).contains(answer.status) else { throw SocketFileHTTPFailure(status: answer.status, body: answer.body) }
        return answer.body
    }

    private func send(method: String, path: String, body: String, headers: [String: String], extra: [String: String],
                      socket: String) async throws -> (status: Int, body: String) {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n"
        for (name, value) in headers.merging(extra, uniquingKeysWith: { mine, _ in mine }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        return try await Self.exchange(head + body, socket: socket, connect: connect, timeout: timeout)
    }

    /// The request sent and its answer read: its status and body.
    @MainActor
    static func exchange(_ request: String, socket: String, connect: SocketFileConnect, timeout: Duration) async throws
        -> (status: Int, body: String) {
        guard let stream = await connect(socket) else { throw SocketFileHTTPFailure(status: 0, body: "no server answers at \(socket)") }
        let reading = Reading()
        let data: Data? = await withCheckedContinuation { continuation in
            reading.continuation = continuation
            stream.receive { chunk in
                if let chunk { reading.data.append(chunk) } else { reading.finish(reading.data) }
            }
            stream.send(Data(request.utf8), sent: nil)
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if reading.finish(nil) { stream.close() }
            }
        }
        guard let data else { throw SocketFileHTTPFailure(status: 0, body: "no answer at \(socket) within \(timeout)") }
        guard let answer = parse(data) else { throw SocketFileHTTPFailure(status: 0, body: "no HTTP answer at \(socket)") }
        return answer
    }

    /// An HTTP answer's status and body (as long as its Content-Length
    /// says, when it says).
    static func parse(_ data: Data) -> (status: Int, body: String)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, let end = (0...(bytes.count - 4)).first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10 && bytes[$0 + 2] == 13
            && bytes[$0 + 3] == 10 }) else { return nil }
        let head = String(decoding: bytes[..<end], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let words = (lines.first ?? "").split(separator: " ")
        guard words.count >= 2, let status = Int(words[1]) else { return nil }
        var body = bytes[(end + 4)...]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length", let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                body = body.prefix(length)
            }
        }
        return (status, String(decoding: body, as: UTF8.self))
    }
}

/// What has come of an answer so far, and who waits for it.
@MainActor
private final class Reading {
    var data = Data()
    var continuation: CheckedContinuation<Data?, Never>?

    /// The answer given to whoever waits, the first time: whether this was.
    @discardableResult
    func finish(_ value: Data?) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}
