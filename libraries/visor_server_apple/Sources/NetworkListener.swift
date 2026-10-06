import Network
import Security
import VisorServer

/// A Network framework listener, on the main queue: connections are taken
/// as they arrive, in order.
@MainActor
final class NetworkListener: Listener {
    private let listener: NWListener

    init(_ options: ListeningOptions, accept: @escaping @MainActor (any ByteStream) -> Void) throws {
        let parameters: NWParameters
        if let tls = options.tls {
            let tlsOptions = NWProtocolTLS.Options()
            guard let identity = Self.identity(tls) else { throw NWError.posix(.EINVAL) }
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)
            parameters = NWParameters(tls: tlsOptions)
        } else {
            parameters = .tcp
        }
        parameters.allowLocalEndpointReuse = true
        // IPv4 only. The default is one IPv6 socket meant to take IPv4 as
        // well, which takes it from the LAN but not through a VPN's tun
        // interface (Tailscale's): the address in the connection code
        // then times out. Every address a code carries is IPv4.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        guard let endpointPort = NWEndpoint.Port(rawValue: options.port) else { throw NWError.posix(.EINVAL) }
        if !options.everywhere { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort) }
        listener = try NWListener(using: parameters, on: options.everywhere ? endpointPort : .any)
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { accept(NetworkStream(connection)) }
        }
        listener.start(queue: .main)
    }

    /// The identity in a PKCS#12 file, as Security hands it over.
    private static func identity(_ tls: TLSIdentity) -> sec_identity_t? {
        var items: CFArray?
        let status = SecPKCS12Import(tls.pkcs12 as CFData, [kSecImportExportPassphrase as String: tls.password] as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let found = first[kSecImportItemIdentity as String] else { return nil }
        let reference = found as CFTypeRef
        guard CFGetTypeID(reference) == SecIdentityGetTypeID() else { return nil }
        // Checked just above: a CF type is cast, not bridged.
        return sec_identity_create(unsafeDowncast(reference, to: SecIdentity.self))
    }

    func stop() {
        listener.cancel()
    }
}
