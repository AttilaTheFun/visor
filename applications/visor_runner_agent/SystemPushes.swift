// The push proxy as this system has it: on a Mac, the key's signatures by
// CryptoKit and APNs reached with URLSession (HTTP/2, which APNs asks
// for); elsewhere, none (a Runner there proxies no pushes).

#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Synchronization
import VisorRunner

enum SystemPushes {
    static func proxy(secrets: RunnerSecrets) -> APNsProxy? {
        APNsProxy(secrets: secrets, signing: CryptoKitSigning(), send: { send($0) })
    }

    private static let session = URLSession(configuration: .ephemeral)

    /// One push to APNs, waited for: the proxy answers on a thread of the
    /// connection's own.
    private static func send(_ push: APNsProxy.Outgoing) -> APNsProxy.Answer {
        guard let url = URL(string: push.url) else { return APNsProxy.Answer(status: 0, body: Data()) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        for (name, value) in push.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = push.body
        let handed = Handed()
        session.dataTask(with: request) { data, response, _ in
            handed.answer.withLock { $0 = APNsProxy.Answer(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data ?? Data()) }
            handed.done.signal()
        }.resume()
        handed.done.wait()
        return handed.answer.withLock { $0 }
    }
}

/// An answer handed from URLSession's queue to the thread waiting for it.
private final class Handed: Sendable {
    let answer = Mutex(APNsProxy.Answer(status: 0, body: Data()))
    let done = DispatchSemaphore(value: 0)
}

/// ES256 with the key in a .p8, as APNs's tokens are signed.
private struct CryptoKitSigning: APNsSigning {
    func sign(_ message: Data, with pem: String) throws -> Data {
        try P256.Signing.PrivateKey(pemRepresentation: pem).signature(for: message).rawRepresentation
    }
}
#else
import VisorRunner

enum SystemPushes {
    /// None: an APNs token is signed with CryptoKit.
    static func proxy(secrets: RunnerSecrets) -> APNsProxy? { nil }
}
#endif
