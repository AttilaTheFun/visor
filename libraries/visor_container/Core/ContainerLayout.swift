// Where the Sessions container's files go: on the Containers volume, in
// `Visor/` (docs/containers.md). All of it can be thrown away and made
// again; what must survive is on Sessions.
//
//   kernel/vmlinux, vmlinux.json        the kernel, and what it was checked against
//   store/                              Containerization's image store (content/, state.json)
//   store/initfs/<digest>.ext4          the init filesystem, unpacked from vminit
//   templates/<digest>-<GiB>.ext4       the agent image's root filesystem, unpacked once
//   tools/<visor version>/              Visor's Linux programs, copied out of the app
//
// TODO(case sensitivity, still open with Logan): where the sessions'
// checkouts live in the container. Sessions is case-insensitive on both
// Macs today and virtiofs passes that on; the proposal is a third,
// case-sensitive APFS volume (`/Volumes/Work`) made by Visor Disk Utility.
// Nothing here decides it: the engine (PR 2) mounts Sessions alone.

import DiskVolumes
import Foundation

public struct ContainerLayout: Equatable, Sendable {
    /// Visor's folder on the Containers volume.
    public static let folderName = "Visor"

    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Visor's folder on the Containers volume as Visor finds it, or an
    /// error naming Visor Disk Utility when it isn't mounted.
    public static func locate(_ volumes: DiskVolumes) throws -> ContainerLayout {
        let containers = volumes.containers
        guard containers.isReady else { throw ContainerAssetsError.noContainersVolume(containers.path) }
        return ContainerLayout(root: URL(fileURLWithPath: containers.path, isDirectory: true).appendingPathComponent(folderName, isDirectory: true))
    }

    public var kernelFolder: URL { root.appendingPathComponent("kernel", isDirectory: true) }
    public var kernel: URL { kernelFolder.appendingPathComponent("vmlinux") }
    /// What the kernel was taken from and its own SHA-256 (KernelRecord).
    public var kernelRecord: URL { kernelFolder.appendingPathComponent("vmlinux.json") }

    /// Containerization's image store.
    public var store: URL { root.appendingPathComponent("store", isDirectory: true) }

    /// The init filesystem unpacked from vminit of that digest.
    public func initfs(digest: String) -> URL {
        store.appendingPathComponent("initfs", isDirectory: true).appendingPathComponent("\(Self.hex(digest)).ext4")
    }

    public var templates: URL { root.appendingPathComponent("templates", isDirectory: true) }

    /// The image's root filesystem, unpacked once, at a size.
    public func template(image: ImageDigest, gib: UInt64 = ContainerPins.templateGiB) -> URL {
        templates.appendingPathComponent("\(image.hex)-\(gib).ext4")
    }

    public var toolsRoot: URL { root.appendingPathComponent("tools", isDirectory: true) }

    /// Visor's Linux programs for a version of Visor, or nil when the
    /// version can't be a folder's name (empty, `.`, `..`, or with a `/`).
    public func tools(version: String) -> URL? {
        guard !version.isEmpty, version != ".", version != "..", !version.contains("/"), !version.contains("\0") else { return nil }
        return toolsRoot.appendingPathComponent(version, isDirectory: true)
    }

    /// A digest's hex digits (`sha256:` dropped).
    static func hex(_ digest: String) -> String {
        digest.hasPrefix("sha256:") ? String(digest.dropFirst("sha256:".count)) : digest
    }
}
