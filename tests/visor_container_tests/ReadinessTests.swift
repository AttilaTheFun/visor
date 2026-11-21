// Settings' readiness row: the container can be turned on only on macOS 26
// or later, on Apple silicon, where Virtualization can make a VM; the volume
// and the assets are shown, and come later.

import DiskVolumes
import Testing
import VisorContainerCore

@Suite struct ReadinessTests {
    static let able = ContainerHost(systemVersion: "26.1", isMacOS26OrLater: true, isAppleSilicon: true, virtualizationSupported: true)
    static let mounted = LocatedVolume(role: .containers, path: "/Volumes/Containers", isMounted: true, record: nil)
    static let unmounted = LocatedVolume(role: .containers, path: "/Volumes/Containers", isMounted: false, record: nil)
    static let image = ImageDigest("sha256:" + String(repeating: "ab", count: 32))!
    static let complete = ContainerAssetStatus(kernel: true, initfs: true, template: true, image: image)

    @Test func everythingThereIsReady() {
        let readiness = ContainerReadiness(host: Self.able, volume: Self.mounted, assets: Self.complete)
        #expect(readiness.canEnable && readiness.isReady)
        #expect(readiness.checks.map(\.name) == ["macOS 26 or later", "Apple silicon", "Virtualization", "Containers volume", "Assets"])
        #expect(readiness.isEnabled(setting: true))
        #expect(!readiness.isEnabled(setting: false))
    }

    @Test func macOS15CantTurnItOn() {
        var host = Self.able
        host.systemVersion = "15.6"
        host.isMacOS26OrLater = false
        let readiness = ContainerReadiness(host: host, volume: Self.mounted, assets: Self.complete)
        #expect(!readiness.canEnable)
        #expect(!readiness.isEnabled(setting: true), "the setting on, it's still off here")
        #expect(readiness.checks[0].detail == "This Mac runs macOS 15.6.")
    }

    @Test func aMacVMCantTurnItOn() {
        var host = Self.able
        host.virtualizationSupported = false
        #expect(!ContainerReadiness(host: host, volume: Self.mounted, assets: Self.complete).canEnable)
        var intel = Self.able
        intel.isAppleSilicon = false
        #expect(!ContainerReadiness(host: intel, volume: Self.mounted, assets: Self.complete).canEnable)
    }

    @Test func noVolumeOrMissingAssetsAreShownButDontStopIt() {
        let noVolume = ContainerReadiness(host: Self.able, volume: Self.unmounted, assets: nil)
        #expect(noVolume.canEnable && !noVolume.isReady)
        #expect(noVolume.checks[3].detail.contains("Visor Disk Utility"))
        let missing = ContainerReadiness(host: Self.able, volume: Self.mounted,
                                         assets: ContainerAssetStatus(kernel: true, initfs: false, template: false, image: Self.image))
        #expect(missing.canEnable && !missing.isReady)
        #expect(missing.checks[4].detail == "Missing the init filesystem and the image's root filesystem; fetched when the container first starts.")
    }
}
