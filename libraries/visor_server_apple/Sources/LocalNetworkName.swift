import SystemConfiguration

/// This Mac's name on its local network, as Bonjour answers it
/// ("Studio-Mac.local"): the one Sharing settings show, which stays the
/// same when the network gives the Mac another address.
public enum LocalNetworkName {
    public static func current() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name + ".local"
    }
}
