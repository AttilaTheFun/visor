#if canImport(Darwin)
import Foundation
import Security
import Synchronization

public final class NativeVisorHTTPService: VisorHTTPService {
    /// Many requests at once: every open transcript holds a long poll, and
    /// a send must not wait behind them. The shared session caps a host at
    /// six connections, which a handful of subscribed sessions exhaust.
    private let httpSession = Mutex(NativeVisorHTTPService.makeSession())

    /// The connections held are let go with whatever was in flight on
    /// them (a held transcript sync fails and is asked again), and the
    /// next request starts on a session of its own.
    public func reset() {
        let old = httpSession.withLock { session in
            let old = session
            session = Self.makeSession()
            return old
        }
        old.invalidateAndCancel()
    }

    private static func makeSession() -> URLSession {
        let http = URLSessionConfiguration.default
        http.waitsForConnectivity = false
        http.httpMaximumConnectionsPerHost = 16
        // A transcript long poll is held on the computer for a while; the
        // per-request timeout in `request` leaves room, and the resource
        // timeout must not cut it short.
        http.timeoutIntervalForRequest = 60
        http.timeoutIntervalForResource = 120
        return URLSession(configuration: http)
    }

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
        let session = httpSession.withLock { $0 }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else { throw VisorHTTPFailure(status: status, body: text) }
        return text
    }
}
#endif
