/// What a computer's network interfaces are, by their names.
public enum NetworkInterfaces {
    /// A bridge to the computer's own containers or virtual machines (a
    /// Mac's `bridge100` for Apple's container, Docker's, libvirt's): its
    /// address is the same on every computer that has one (192.168.64.1),
    /// so a client given it for one computer reached another — its own —
    /// and took that one for this. Never one of the addresses a server
    /// gives.
    public static func isBridge(_ name: String) -> Bool {
        ["bridge", "docker", "br-", "virbr", "cni", "lxc"].contains { name.hasPrefix($0) }
    }
}
