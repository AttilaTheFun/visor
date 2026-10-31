import Synchronization
import VisorRunner

/// The MCP servers the Runner's proxy passes calls on to, as they are set
/// now: kept from the Mac server's settings for the threads that read them
/// (the proxy's, the container servers').
final class MCPEndpointList: Sendable {
    private let held = Mutex<[MCPProxy.Endpoint]>([])

    var value: [MCPProxy.Endpoint] {
        get { held.withLock { $0 } }
        set { held.withLock { $0 = newValue } }
    }
}
