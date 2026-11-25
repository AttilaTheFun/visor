// Where the Sessions container's files go: on the Visor volume, in
// `Containers/` (docs/containers.md). All of it can be thrown away and made
// again; what must survive is on Sessions, and the sessions' checkouts on
// Sources.
//
//   kernel/vmlinux, vmlinux.json        the kernel, and what it was checked against
//   store/                              Containerization's image store (content/, state.json)
//   store/initfs/<digest>.ext4          the init filesystem, unpacked from vminit
//   templates/<digest>-<GiB>.ext4       the agent image's root filesystem, unpacked once
//   tools/<visor version>/              Visor's Linux programs, copied out of the app
//   sessions/rootfs.ext4, rootfs.json   the Sessions container's root filesystem (a clone
//                                       of the template) and the image it was cloned from
//   sessions/boot.log                   the guest's console, each boot
//   sessions/logs/<process>.log         each process exec'd in it
//   sessions/trust/                     agent-proxy's authorities' certificates, staged
//                                       each boot (public; never a key)

import DiskVolumes
import Foundation

public struct ContainerLayout: Equatable, Sendable {
    /// The container's folder on the Visor volume.
    public static let folderName = VisorFolders.containersName

    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The container's folder on the Visor volume as Visor finds it, or an
    /// error naming Visor Disk Utility when it isn't mounted.
    public static func locate(_ volumes: DiskVolumes) throws -> ContainerLayout {
        let visor = volumes.visor
        guard visor.isReady else { throw ContainerAssetsError.noVisorVolume(visor.path) }
        return ContainerLayout(root: URL(fileURLWithPath: visor.path, isDirectory: true).appendingPathComponent(folderName, isDirectory: true))
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

    /// The Sessions container's own: its root filesystem, its record, its
    /// boot log and its processes' logs.
    public var sessionsFolder: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var rootfs: URL { sessionsFolder.appendingPathComponent("rootfs.ext4") }
    /// Which image the root filesystem was cloned from (RootfsRecord).
    public var rootfsRecord: URL { sessionsFolder.appendingPathComponent("rootfs.json") }
    public var bootLog: URL { sessionsFolder.appendingPathComponent("boot.log") }
    public var logs: URL { sessionsFolder.appendingPathComponent("logs", isDirectory: true) }
    /// agent-proxy's authorities' certificates, shared read-only at
    /// ContainerEngine.trustInGuest.
    public var trust: URL { sessionsFolder.appendingPathComponent("trust", isDirectory: true) }

    /// A process's log, by its id (letters, digits, `-`, `_` and `.`; any
    /// other character a `_`).
    public func log(process id: String) -> URL {
        let safe = String(id.map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) ? $0 : "_" })
        return logs.appendingPathComponent("\(safe.isEmpty || safe.hasPrefix(".") ? "_" + safe : safe).log")
    }

    /// A digest's hex digits (`sha256:` dropped).
    static func hex(_ digest: String) -> String {
        digest.hasPrefix("sha256:") ? String(digest.dropFirst("sha256:".count)) : digest
    }
}
