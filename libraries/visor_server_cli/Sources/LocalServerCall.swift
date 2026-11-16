// A REST call to the server running on this computer, over its trusted
// socket (VisorServer.socketPath, this user's alone): what `visor-server
// admin-token` and `visor-server keys` ask of it, the menu bar app's
// server or the command-line one alike. One request, its answer read until
// the server closes the connection, as it does after each.

import Foundation
import VisorServer
import VisorSystem

struct LocalServerCall {
    let method: String
    let path: String
    /// Shown as `Authorization: Bearer`, if any.
    var bearer: String? = nil
    var body: String = ""

    /// The status and body of the answer.
    @MainActor
    func send(through system: any CommandLineSystem, socket: String? = nil) async throws(CommandLineError) -> (status: Int, body: String) {
        let socket = socket ?? VisorServer.socketPath
        guard let stream = await system.connect(unixPath: socket) else {
            throw .failed("no server answers at \(socket): is it running, with `ssh on` (its trusted socket)?")
        }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
        if let bearer { head += "Authorization: Bearer \(bearer)\r\n" }
        head += "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        let received: Data = await withCheckedContinuation { continuation in
            let answer = Received()
            stream.receive { chunk in
                guard !answer.done else { return }
                if let chunk {
                    answer.data.append(chunk)
                } else {
                    answer.done = true
                    continuation.resume(returning: answer.data)
                }
            }
            stream.send(Data((head + body).utf8), sent: nil)
        }
        stream.close()
        guard let answer = Self.parse(received) else { throw .failed("the server's answer at \(socket) couldn't be read") }
        return answer
    }

    /// An HTTP answer's status and body.
    static func parse(_ data: Data) -> (status: Int, body: String)? {
        let text = String(decoding: data, as: UTF8.self)
        guard let split = text.range(of: "\r\n\r\n") else { return nil }
        let statusLine = text[..<split.lowerBound].split(separator: "\r\n").first ?? ""
        let words = statusLine.split(separator: " ")
        guard words.count >= 2, let status = Int(words[1]) else { return nil }
        return (status, String(text[split.upperBound...]))
    }
}

/// What has come of an answer so far.
@MainActor
private final class Received {
    var data = Data()
    var done = false
}
