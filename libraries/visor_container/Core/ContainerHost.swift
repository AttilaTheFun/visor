// What this computer is, as far as the Sessions container cares: it runs
// only on Apple silicon, macOS 26 or later, where Virtualization.framework
// can make a VM (VZVirtualMachine.isSupported: not in a macOS VM, which
// can't nest). VisorContainer's `ContainerHost.current` reads this Mac's.

public struct ContainerHost: Equatable, Sendable {
    /// macOS's version, `26.1`.
    public var systemVersion: String
    /// Whether it's macOS 26 or later.
    public var isMacOS26OrLater: Bool
    public var isAppleSilicon: Bool
    /// VZVirtualMachine.isSupported.
    public var virtualizationSupported: Bool

    public init(systemVersion: String, isMacOS26OrLater: Bool, isAppleSilicon: Bool, virtualizationSupported: Bool) {
        self.systemVersion = systemVersion
        self.isMacOS26OrLater = isMacOS26OrLater
        self.isAppleSilicon = isAppleSilicon
        self.virtualizationSupported = virtualizationSupported
    }

    /// Whether the container can run here at all.
    public var canRunContainer: Bool { isMacOS26OrLater && isAppleSilicon && virtualizationSupported }
}
