// Where a wrapped agent's MCP bridge (DrivenMCP) writes: down the wrapper's
// connection as DriverMessage.mcp, for its MCP connection (`client`). An
// answer goes under the wrapper's id for the request it answers; what the
// bridge says unasked (notifications/tools/list_changed), with none.

import AgentProtocol
import Synchronization
import VisorMCPBridge
import VisorProtocol

final class DrivenMCPOutput: MCPOutput {
    let client: String
    private let deliver: @Sendable (AgentProtocol_V1_DriverMessage) -> Void
    /// The wrapper's id for each request still unanswered, by its JSON-RPC id.
    private let asked = Mutex<[String: String]>([:])

    init(client: String, deliver: @escaping @Sendable (AgentProtocol_V1_DriverMessage) -> Void) {
        self.client = client
        self.deliver = deliver
    }

    /// The request with JSON-RPC id `rpcID` is the wrapper's `id`.
    func expect(_ rpcID: JSONValue, as id: String) {
        asked.withLock { $0[rpcID.encoded()] = id }
    }

    func send(_ message: JSONValue) {
        var id = ""
        // An answer (an id, and no method): to the request it answers, or
        // to nothing, and dropped.
        if !message["id"].isNull, message["method"].isNull {
            guard let given = asked.withLock({ $0.removeValue(forKey: message["id"].encoded()) }) else { return }
            id = given
        }
        let json = message.encoded()
        let client = self.client
        deliver(.with { $0.mcp = .with { $0.id = id; $0.json = json; $0.client = client } })
    }
}
