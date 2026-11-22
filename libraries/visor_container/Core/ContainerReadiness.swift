// Settings' readiness row for the Sessions container: this Mac (macOS 26
// or later, Apple silicon, virtualization), the Visor volume, and the
// assets on it. The container can be turned on only where this Mac can run
// it; the volume and the assets are made or fetched later (Visor Disk
// Utility, and the engine when it first starts).

import DiskVolumes

public struct ContainerReadiness: Equatable, Sendable {
    /// One line of the row.
    public struct Check: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var ok: Bool
        public var detail: String

        public init(name: String, ok: Bool, detail: String) {
            self.name = name
            self.ok = ok
            self.detail = detail
        }
    }

    public var host: ContainerHost
    public var checks: [Check]

    /// `assets` nil: the volume isn't there to look on.
    public init(host: ContainerHost, volume: LocatedVolume, assets: ContainerAssetStatus?) {
        self.host = host
        var checks = [
            Check(name: "macOS 26 or later", ok: host.isMacOS26OrLater, detail: "This Mac runs macOS \(host.systemVersion)."),
            Check(name: "Apple silicon", ok: host.isAppleSilicon,
                  detail: host.isAppleSilicon ? "This Mac has Apple silicon." : "The container needs a Mac with Apple silicon."),
            Check(name: "Virtualization", ok: host.virtualizationSupported,
                  detail: host.virtualizationSupported ? "This Mac can run virtual machines."
                                                       : "Virtualization isn't available here (a Mac VM can't run another)."),
            Check(name: "Visor volume", ok: volume.isReady,
                  detail: volume.isReady ? "Mounted at \(volume.path)." : "No volume at \(volume.path): make it with Visor Disk Utility."),
        ]
        if let assets {
            checks.append(Check(name: "Assets", ok: assets.isComplete,
                                detail: assets.isComplete ? "The kernel, the init filesystem and image \(assets.image?.short ?? "") are on the volume."
                                                          : "Missing \(Self.list(assets.missing)); fetched when the container first starts."))
        } else {
            checks.append(Check(name: "Assets", ok: false, detail: "Fetched onto the Visor volume once there is one."))
        }
        self.checks = checks
    }

    /// Whether the container may be turned on: this Mac can run it.
    public var canEnable: Bool { host.canRunContainer }

    /// Whether it could start now with nothing to fetch.
    public var isReady: Bool { checks.allSatisfy(\.ok) }

    /// The setting as it takes effect: off wherever it can't run.
    public func isEnabled(setting: Bool) -> Bool { setting && canEnable }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
