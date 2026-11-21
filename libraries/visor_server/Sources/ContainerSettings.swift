// The Sessions container's settings (docs/containers.md): whether it's on,
// its CPUs and memory, how long it stays up with no session in it, and an
// image digest in place of the release's. Kept in the server's settings
// (`ServerSettings.container`); none there is these defaults, and off.
// The container itself is the Mac's (libraries/visor_container): these are
// only what's kept.

import Foundation

public struct ContainerSettings: Codable, Equatable, Sendable {
    /// Whether sessions may be placed in the container. Off by default; it
    /// takes effect only on a Mac that can run it (macOS 26 or later, Apple
    /// silicon, virtualization), whatever this says.
    public var enabled = false
    /// Its CPUs; nil for the default (ContainerSettings.defaultCPUs).
    public var cpus: Int?
    /// Its memory in GiB; nil for the default, sized when it starts from
    /// what's free then (ContainerSettings.defaultMemoryGiB).
    public var memoryGiB: Int?
    /// Minutes with no session in it before it's stopped (its memory given
    /// back: what the guest frees isn't, while it runs).
    public var idleMinutes = 30
    /// An image digest (`sha256:…`) in place of the one the release pins
    /// in container.json, of the same repository
    /// (ghcr.io/attilathefun/visor-agent): never a tag. Nil for the
    /// release's.
    public var imageDigest: String?
    /// A folder of this Mac's for the sessions' checkouts, mounted
    /// read-write at the same path in the container (an absolute path);
    /// nil: none, the checkouts are on Sessions. Where they belong is still
    /// open (docs/containers.md: Sessions is case-insensitive on both Macs,
    /// and the proposal is a case-sensitive `/Volumes/Work`), so it's a
    /// setting rather than a decision.
    public var checkouts: String?

    public init() {}

    /// The most the default gives it: on the Mini (32 GB), Nimbus's VMs and
    /// containers need room too.
    public static let defaultMemoryCapGiB = 24
    /// The least it's given.
    public static let minimumMemoryGiB = 4

    /// The default CPUs: eight, leaving two of this Mac's for itself.
    public static func defaultCPUs(cores: Int) -> Int { min(8, max(1, cores - 2)) }

    /// The default memory: half of what's free (and reclaimable) now, so
    /// Nimbus and this Mac's own apps keep the rest, at least
    /// `minimumMemoryGiB` and at most `defaultMemoryCapGiB`; half of all of
    /// it when what's free isn't known. Never more than all of it less 4 GiB.
    public static func defaultMemoryGiB(availableBytes: UInt64?, physicalBytes: UInt64) -> Int {
        let gib: UInt64 = 1 << 30
        let half = (availableBytes ?? physicalBytes) / 2 / gib
        let sized = min(UInt64(defaultMemoryCapGiB), max(UInt64(minimumMemoryGiB), half))
        let ceiling = physicalBytes / gib > 4 ? physicalBytes / gib - 4 : 1
        return Int(min(sized, ceiling))
    }

    /// The CPUs it starts with: the setting, within this Mac's, or the default.
    public func resolvedCPUs(cores: Int) -> Int {
        guard let cpus else { return Self.defaultCPUs(cores: cores) }
        return min(max(cpus, 1), max(cores, 1))
    }

    /// The memory it starts with, in GiB: the setting (at least 1, at most
    /// all of this Mac's less 4 GiB), or the default.
    public func resolvedMemoryGiB(availableBytes: UInt64?, physicalBytes: UInt64) -> Int {
        guard let memoryGiB else { return Self.defaultMemoryGiB(availableBytes: availableBytes, physicalBytes: physicalBytes) }
        let total = Int(physicalBytes >> 30)
        return min(max(memoryGiB, 1), max(total - 4, 1))
    }

    /// Whether `text` is a digest the override takes: `sha256:` and 64
    /// lowercase hex digits.
    public static func isImageDigest(_ text: String) -> Bool {
        guard text.hasPrefix("sha256:") else { return false }
        let hex = text.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    enum CodingKeys: String, CodingKey { case enabled, cpus, memoryGiB, idleMinutes, imageDigest, checkouts }

    // Field by field: one missing, or not what it should be, reads as its
    // default (an image digest that isn't one is dropped: the release's
    // stands).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? false
        cpus = ((try? c.decodeIfPresent(Int.self, forKey: .cpus)) ?? nil).flatMap { $0 > 0 ? $0 : nil }
        memoryGiB = ((try? c.decodeIfPresent(Int.self, forKey: .memoryGiB)) ?? nil).flatMap { $0 > 0 ? $0 : nil }
        idleMinutes = ((try? c.decodeIfPresent(Int.self, forKey: .idleMinutes)) ?? nil).flatMap { $0 > 0 ? $0 : nil } ?? 30
        let digest = ((try? c.decodeIfPresent(String.self, forKey: .imageDigest)) ?? nil)?.trimmingCharacters(in: .whitespaces)
        imageDigest = digest.flatMap { Self.isImageDigest($0) ? $0 : nil }
        let folder = ((try? c.decodeIfPresent(String.self, forKey: .checkouts)) ?? nil)?.trimmingCharacters(in: .whitespaces)
        checkouts = folder.flatMap { $0.hasPrefix("/") && $0.count > 1 ? $0 : nil }
    }
}
