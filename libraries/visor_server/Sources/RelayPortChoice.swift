// agent-proxy's relay port when the Sessions container is turned on and
// none is set (docs/containers.md): the container's only way out, so one
// must be. A free port on loopback, Visor's own first (7438, beside the
// server's 7433, the driver's 7434 and the MCP pass-through's 7439), then
// the next free above it; never one of Visor's own, nor Shireworks' 7499
// (the Mini's Shireworks relays its own containers there, and a port free
// while it's stopped would be taken from it).

public enum RelayPortChoice {
    /// Visor's relay port, when it's free.
    public static let preferred = 7438
    /// Never chosen: Visor's server, driver and MCP pass-through, and
    /// Shireworks' relay.
    public static let avoided: Set<Int> = [7433, 7434, 7439, 7499]
    /// Where the search goes after `preferred`.
    public static let candidates = Array(7440...7498) + Array(7500...7599)

    /// The first port free (`isFree`) and not avoided (`avoided`, and
    /// `alsoAvoided`: the MCP pass-through's, if it's elsewhere); nil when
    /// none of them is.
    public static func choose(alsoAvoided: Set<Int> = [], isFree: (Int) -> Bool) -> Int? {
        let avoid = avoided.union(alsoAvoided)
        return ([preferred] + candidates).first { !avoid.contains($0) && isFree($0) }
    }
}
