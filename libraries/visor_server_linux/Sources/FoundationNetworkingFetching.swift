import Foundation
import FoundationNetworking
import VisorServer

/// Requests through Foundation's URLSession, which on Linux is libcurl's.
public struct FoundationNetworkingFetching: HTTPFetching {
    public init() {}

    public func fetch(_ request: OutgoingRequest) async throws -> OutgoingRequest.Answer {
        guard let url = URL(string: request.url) else { throw URLError(.badURL) }
        var outgoing = URLRequest(url: url, timeoutInterval: request.timeout)
        outgoing.httpMethod = request.method
        for (name, value) in request.headers { outgoing.setValue(value, forHTTPHeaderField: name) }
        if !request.body.isEmpty { outgoing.httpBody = request.body }
        let (data, response) = try await URLSession.shared.data(for: outgoing)
        return OutgoingRequest.Answer(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
