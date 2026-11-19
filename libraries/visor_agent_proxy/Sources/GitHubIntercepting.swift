import Foundation

/// What opens a CONNECT to one of GitHub's hosts on port 443 in place of a
/// tunnel: GitHubInterceptor (agent-proxy's own authority's certificate,
/// GitHubGate's rules, the configured auth token). None: the egress proxy
/// tunnels GitHub as it does any host.
public protocol GitHubIntercepting: Sendable {
    /// Whether this CONNECT is the interceptor's to open (GitHub's host,
    /// port 443, as it decides).
    func intercepts(_ destination: EgressProxy.Destination) -> Bool

    /// The client's stream, its CONNECT already answered 200 and nothing of
    /// its own read past that: the interceptor's from here, to close. It
    /// returns once the stream has closed (the relay listener counts it
    /// until then).
    func adopt(_ client: Int32, host: String, caller: EgressProxy.Caller)
}
