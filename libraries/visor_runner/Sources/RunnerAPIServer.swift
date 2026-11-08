import CVisorPOSIX
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// The Runner's side for clients (RunnerAPI) on a port of its own
/// (runner.json's `apiPort`), every interface, over TLS with the Runner's
/// own certificate (RunnerIdentity), which a client pins by its
/// fingerprint: a password never crosses a network in the clear. The
/// tailnet's certificate in its place is docs/runner-accounts.md's next
/// part of step 3.
public final class RunnerAPIServer: Sendable {
    public let port: UInt16
    private let listener: Int32
    private let api: RunnerAPI
    private let reach: @Sendable (String) -> Reach?
    private let context: NIOSSLContext
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    /// Nil when the port can't be had.
    /// With the Runner's own certificate (RunnerIdentity).
    public convenience init?(port: UInt16, api: RunnerAPI, identity: RunnerIdentity,
                             reach: @escaping @Sendable (String) -> Reach? = { _ in nil }) throws {
        try self.init(port: port, api: api, chain: try identity.pem, key: identity.keyPEM, reach: reach)
    }

    /// With a certificate chain and its key as PEM: the Runner's own, or one
    /// a client trusts as any website's (the tailnet's, from `tailscale
    /// cert`: its leaf, then the authority that signed it).
    /// `reach`: where a server the Runner passes requests on to is, and its
    /// password (runner.json's `reaches`, the secrets'), at each request.
    public init?(port: UInt16, api: RunnerAPI, chain: String, key: String,
                 reach: @escaping @Sendable (String) -> Reach? = { _ in nil }) throws {
        let certificates = try NIOSSLCertificate.fromPEMBytes(Array(chain.utf8))
        guard !certificates.isEmpty else { throw RunnerAPIServer.NoCertificate() }
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.utf8), format: .pem)))
        configuration.applicationProtocols = ["http/1.1"]
        context = try NIOSSLContext(configuration: configuration)
        visor_ignore_broken_pipes()
        let listener = visor_listen(port, 1)
        guard listener >= 0 else { return nil }
        self.port = port
        self.listener = listener
        self.api = api
        self.reach = reach
    }

    public func start() {
        Thread.detachNewThread { [self] in
            while true {
                let client = visor_accept(listener)
                if client < 0 { return }
                adopt(client)
            }
        }
    }

    public func stop() {
        visor_shutdown(listener)
        close(listener)
        group.shutdownGracefully { _ in }
    }

    /// A chain with no certificate in it.
    public struct NoCertificate: Error, CustomStringConvertible {
        public var description: String { "no certificate in the chain given" }
    }

    /// The names of the client's HTTP handlers.
    enum Names {
        static let encoder = "http-encoder"
        static let decoder = "http-decoder"
        static let errors = "http-errors"
        static let handler = "runner-api"
    }

    /// A client's connection: TLS, then its requests.
    private func adopt(_ socket: Int32) {
        let context = self.context
        let api = self.api
        let reach = self.reach
        ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let operations = channel.pipeline.syncOperations
                    try operations.addHandler(NIOSSLServerHandler(context: context))
                    // By name, so a WebSocket's upgrade can take the HTTP
                    // handlers off again (RunnerAPIServer+Proxy.swift); the
                    // decoder hands on what it read past the request.
                    try operations.addHandler(HTTPResponseEncoder(), name: Names.encoder)
                    try operations.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                                              name: Names.decoder)
                    try operations.addHandler(HTTPServerProtocolErrorHandler(), name: Names.errors)
                    try operations.addHandler(Handler(api: api, reach: reach), name: Names.handler)
                }
            }
            .withConnectedSocket(socket)
            .whenFailure { _ in }
    }
}
