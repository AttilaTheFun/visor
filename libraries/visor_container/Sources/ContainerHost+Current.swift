// This Mac, as the container's readiness reads it.

import Foundation
import Virtualization
import VisorContainerCore

extension ContainerHost {
    /// This Mac's: its macOS, its chip (`hw.optional.arm64`, true for an
    /// Apple silicon Mac even in a process under Rosetta), and whether
    /// Virtualization.framework can make a VM here.
    public static var current: ContainerHost {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let appleSilicon = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0 && arm64 == 1
        return ContainerHost(
            systemVersion: version.patchVersion == 0 ? "\(version.majorVersion).\(version.minorVersion)"
                                                     : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            isMacOS26OrLater: info.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)),
            isAppleSilicon: appleSilicon,
            virtualizationSupported: VZVirtualMachine.isSupported)
    }
}
