// Whether a TCP port on loopback is free now: what agent-proxy's relay port
// is chosen by when the Sessions container is turned on (RelayPortChoice).

import CAgentProxyPOSIX
import Foundation

public enum LoopbackPort {
    /// Whether 127.0.0.1:`port` can be listened on now, and nothing
    /// answers there (a listener on every address could share it).
    public static func isFree(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let answered = agent_proxy_connect_tcp("127.0.0.1", UInt16(port))
        if answered >= 0 {
            close(answered)
            return false
        }
        let listener = agent_proxy_listen(UInt16(port), 0)
        guard listener >= 0 else { return false }
        close(listener)
        return true
    }
}
