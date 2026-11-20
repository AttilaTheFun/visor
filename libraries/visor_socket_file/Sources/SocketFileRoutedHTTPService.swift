/// The host's HTTP service with a server's socket file beside it: a
/// socket file's URL (SocketFileURL) goes there, every other to the host's
/// own, as before.
import VisorProtocol
import VisorServices

public final class SocketFileRoutedHTTPService: VisorHTTPService {
    private let socketFile: SocketFileHTTPService
    private let other: any VisorHTTPService

    public init(socketFile: SocketFileHTTPService, other: any VisorHTTPService) {
        self.socketFile = socketFile
        self.other = other
    }

    public func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        if SocketFileURL.isSocketFile(url) { return try await socketFile.request(method: method, url: url, body: body, authorization: authorization) }
        return try await other.request(method: method, url: url, body: body, authorization: authorization)
    }

    public func request(method: String, url: String, body: String, headers: [String: String]) async throws -> String {
        if SocketFileURL.isSocketFile(url) { return try await socketFile.request(method: method, url: url, body: body, headers: headers) }
        return try await other.request(method: method, url: url, body: body, headers: headers)
    }

    public func status(of error: Error) -> Int? { socketFile.status(of: error) ?? other.status(of: error) }
    public func body(of error: Error) -> String? { socketFile.body(of: error) ?? other.body(of: error) }
    public func reset() { other.reset() }
}
