// `visor-agent-host mcp-headers`: the headers a Sessions container agent's
// Claude shows agent-proxy's MCP pass-through (docs/containers.md, "MCP in
// the container"), as the pass-through's servers' headersHelper. Claude Code
// runs it as it connects to each of them, and again when one answers 401
// (which it does because the headers include `Authorization`), and takes
// the JSON object it prints as the headers.
// It asks the agent's wrapper for them on the wrapper's MCP socket
// (AGENT_MCP_SOCKET, which the wrapper gives its harness): one JSON-RPC
// request, `visor/passThroughHeaders`, which the wrapper relays to Visor's
// driver as it does any of its harness's MCP, over the stream its own token
// opened; Visor answers with a fresh token of the agent's (a week's, for
// MCP alone, no one's once its agent ends), as `X-Visor-Proxy` and as
// `Authorization: Bearer`. Nothing is kept: no file, no variable, no
// command line has it.

import CVisorPOSIX
import Foundation
import VisorProtocol

public enum MCPHeadersMain {
    /// Where the wrapper's MCP socket is (agent_protocol's
    /// mcpSocketVariable), in its harness's environment.
    static let socketVariable = "AGENT_MCP_SOCKET"
    /// The request's method and id.
    static let method = "visor/passThroughHeaders"
    static let requestID = "visor-pass-through-headers"
    /// How long the wrapper has to answer, in seconds.
    static let within = 10

    /// Why there are no headers: said on standard error, which Claude Code
    /// logs.
    struct Failure: Error, Equatable {
        let message: String
    }

    /// Prints the headers, a JSON object, and ends 0; else says why, and
    /// ends 1.
    public static func run(_ environment: [String: String]) -> Int32 {
        switch headers(socket: environment[socketVariable] ?? "") {
        case .success(let headers):
            FileHandle.standardOutput.write(Data((headers.encoded() + "\n").utf8))
            return 0
        case .failure(let failure):
            FileHandle.standardError.write(Data(("visor-agent-host mcp-headers: " + failure.message + "\n").utf8))
            return 1
        }
    }

    /// The headers the wrapper at `path` answers with, asked once.
    static func headers(socket path: String, within seconds: Int = MCPHeadersMain.within) -> Result<JSONValue, Failure> {
        guard !path.isEmpty else {
            return .failure(Failure(message: "\(socketVariable) isn't set: Claude runs this under its agent's wrapper, in the Sessions container"))
        }
        let descriptor = visor_connect_unix(path)
        guard descriptor >= 0 else { return .failure(Failure(message: "no wrapper answers at \(path)")) }
        defer { mcpClose(descriptor) }
        visor_set_receive_timeout(descriptor, Int32(seconds))
        let request = JSONValue.object(["jsonrpc": .string("2.0"), "id": .string(requestID), "method": .string(method)])
        guard mcpWriteAll(descriptor, Array((request.encoded() + "\n").utf8)) else {
            return .failure(Failure(message: "the wrapper at \(path) took nothing"))
        }
        // Its answer is the line of this request's id: any other (a
        // notification) is passed over.
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 << 10)
        while received.count < 1 << 20 {
            while let end = received.firstIndex(of: 0x0A) {
                let line = String(decoding: received[..<end], as: UTF8.self)
                received.removeSubrange(...end)
                if let answer = parseJSON(line), answer["id"].string == requestID { return taken(answer) }
            }
            guard let count = mcpRead(descriptor, into: &chunk) else { break }
            received += chunk[0..<count]
        }
        return .failure(Failure(message: "the wrapper didn't answer within \(seconds) seconds"))
    }

    /// The headers in the wrapper's answer: a JSON object of strings; else
    /// why not, as the driver said.
    static func taken(_ answer: JSONValue) -> Result<JSONValue, Failure> {
        let headers = answer["result"]["headers"]
        guard let fields = headers.object, !fields.isEmpty, fields.values.allSatisfy({ $0.string?.isEmpty == false }) else {
            return .failure(Failure(message: answer["error"]["message"].string ?? "the driver answered with no headers"))
        }
        return .success(headers)
    }
}
