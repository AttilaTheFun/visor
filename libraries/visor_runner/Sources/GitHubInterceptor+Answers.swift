import Foundation
import NIOCore
import NIOHTTP1

// What the interceptor writes itself (docs/github-gate-rules.md, §3): a
// refusal in its client's own form, so gh, git and curl each show it as they
// show GitHub's errors; a body with a field a check set; GitHub's answers
// with the token taken out, should one echo it.

extension GitHubInterceptor {
    /// A refusal ("Refused: …") or a failure ("Failed: …") as `method` `uri`
    /// on `host` is answered: REST's 403 (502) JSON, GraphQL's errors, git's
    /// ERR line or report-status.
    static func refusal(_ reason: String, failed: Bool, method: HTTPMethod, host: String, uri: String,
                        body: [UInt8]?) -> (HTTPResponseHead, [UInt8]) {
        let said = (failed ? "Failed: " : "Refused: ") + reason
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        func head(_ status: HTTPResponseStatus, _ type: String, _ length: Int) -> HTTPResponseHead {
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: type)
            headers.add(name: "content-length", value: "\(length)")
            return HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        }
        func json(_ object: [String: Any]) -> [UInt8] {
            Array((try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data())
        }
        if host == "github.com" {
            if path.hasSuffix("/info/refs"), let service = uri.split(separator: "=").last.map(String.init),
               ["git-upload-pack", "git-receive-pack"].contains(service) {
                let bytes = pkt("ERR \(said)\n")
                return (head(.ok, "application/x-\(service)-advertisement", bytes.count), bytes)
            }
            if method == .POST, path.hasSuffix("/git-receive-pack"), let body, case .list(let list, _) = GitPushCommands.read(body),
               !list.commands.isEmpty {
                // report-status, each ref turned down, in side-band if asked.
                var report = pkt("unpack ok\n")
                for command in list.commands { report += pkt("ng \(command.ref) \(said)\n") }
                report += Array("0000".utf8)
                var bytes = report
                if list.capabilities.contains("side-band-64k") || list.capabilities.contains("side-band") {
                    bytes = pkt([1] + report) + Array("0000".utf8)
                }
                return (head(.ok, "application/x-git-receive-pack-result", bytes.count), bytes)
            }
            let bytes = Array((said + "\n").utf8)
            return (head(failed ? .badGateway : .forbidden, "text/plain; charset=utf-8", bytes.count), bytes)
        }
        if path == "/graphql" {
            let bytes = json(["errors": [["type": "FORBIDDEN", "message": said]]])
            return (head(.ok, "application/json; charset=utf-8", bytes.count), bytes)
        }
        let bytes = json(["message": said])
        return (head(failed ? .badGateway : .forbidden, "application/json; charset=utf-8", bytes.count), bytes)
    }

    /// One pkt-line.
    static func pkt(_ text: String) -> [UInt8] { pkt(Array(text.utf8)) }

    static func pkt(_ bytes: [UInt8]) -> [UInt8] {
        Array(String(format: "%04x", bytes.count + 4).utf8) + bytes
    }

    /// A body with what a check set (nil when it can't be set: no JSON
    /// object, or no such variable).
    static func rewritten(_ data: Data, _ rewrite: CheckOutcome.Rewrite) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        switch rewrite {
        case .bodyFieldIfAbsent(let field, let value):
            if object[field] == nil || object[field] is NSNull { object[field] = value.foundation }
        case .variableField(let variable, let field, let value):
            guard var variables = object["variables"] as? [String: Any], var input = variables[variable] as? [String: Any] else { return nil }
            input[field] = value.foundation
            variables[variable] = input
            object["variables"] = variables
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    /// `buffer` with `token`, should it appear, masked by as many `*`s: GitHub
    /// never echoes it, but an answer that did would hand it to the agent. Of
    /// the same length, so the answer's Content-Length still holds.
    static func scrubbed(_ buffer: ByteBuffer, _ token: String) -> ByteBuffer {
        guard !token.isEmpty, buffer.readableBytes >= token.utf8.count else { return buffer }
        let bytes = Array(buffer.readableBytesView)
        let needle = Array(token.utf8)
        guard let first = bytes.firstRange(of: needle) else { return buffer }
        var out = Array(bytes[..<first.lowerBound])
        var rest = bytes[first.lowerBound...]
        let mark = [UInt8](repeating: UInt8(ascii: "*"), count: needle.count)
        while let found = rest.firstRange(of: needle) {
            out += rest[rest.startIndex..<found.lowerBound]
            out += mark
            rest = rest[found.upperBound...]
        }
        out += rest
        var scrubbed = ByteBufferAllocator().buffer(capacity: out.count)
        scrubbed.writeBytes(out)
        return scrubbed
    }
}
