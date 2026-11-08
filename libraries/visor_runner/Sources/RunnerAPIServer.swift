import CVisorPOSIX
import Foundation

/// The Runner's side for clients (RunnerAPI) on a port of its own
/// (runner.json's `apiPort`), every interface, plain HTTP for now: HTTPS,
/// with the tailnet's certificate or the Runner's own, is step 3 of
/// docs/runner-accounts.md. A refused sign-in is answered after a second,
/// so a password isn't guessed quickly.
public final class RunnerAPIServer: Sendable {
    public let port: UInt16
    private let listener: Int32
    private let api: RunnerAPI

    /// Nil when the port can't be had.
    public init?(port: UInt16, api: RunnerAPI) {
        visor_ignore_broken_pipes()
        let listener = visor_listen(port, 1)
        guard listener >= 0 else { return nil }
        self.port = port
        self.listener = listener
        self.api = api
    }

    public func start() {
        Thread.detachNewThread { [self] in
            while true {
                let client = visor_accept(listener)
                if client < 0 { return }
                Thread.detachNewThread { [self] in
                    answer(client)
                    close(client)
                }
            }
        }
    }

    public func stop() {
        visor_shutdown(listener)
        close(listener)
    }

    private func answer(_ client: Int32) {
        guard let request = MCPProxy.read(client) else { return }
        let answer = api.answer(method: request.method, path: request.path, authorization: request.header("authorization"), body: request.body)
        if answer.status == 401, request.method == "POST" { Thread.sleep(forTimeInterval: 1) }
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][answer.status] ?? "Error"
        let head = "HTTP/1.1 \(answer.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(answer.body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        MCPProxy.send(client, Data(head.utf8) + answer.body)
    }
}
