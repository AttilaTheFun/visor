// The interceptors the egress proxy has (its GitHubIntercepting seam):
// GitHub's (GitHubInterceptor) and Anthropic's (AnthropicInterceptor), each
// opening its own hosts; a CONNECT neither takes is a tunnel.

import Foundation

/// Several interceptors as one: the first that takes a CONNECT opens it.
public struct Interceptors: GitHubIntercepting {
    public let all: [any GitHubIntercepting]

    public init(_ all: [any GitHubIntercepting]) { self.all = all }

    public func intercepts(_ destination: EgressProxy.Destination) -> Bool {
        all.contains { $0.intercepts(destination) }
    }

    public func adopt(_ client: Int32, host: String, caller: EgressProxy.Caller) {
        guard let taker = all.first(where: { $0.intercepts(EgressProxy.Destination(host: host, port: 443)) }) else {
            close(client)
            return
        }
        taker.adopt(client, host: host, caller: caller)
    }
}
