// Why the container's assets couldn't be had, for a person.

import Foundation

public enum ContainerAssetsError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    /// The Containers volume isn't mounted where Visor looks.
    case noContainersVolume(String)
    /// A download's SHA-256 wasn't the one pinned.
    case checksumMismatch(what: String, expected: String, found: String)
    /// The kernel isn't in its archive at the path pinned.
    case memberMissing(String)
    /// An image pulled isn't of the digest pinned.
    case digestMismatch(what: String, expected: String, found: [String])
    /// No image digest: no container.json in the app and none in Settings.
    case noImagePinned
    /// Visor's Linux programs folder has an entry the link rule refuses.
    case toolRefused(name: String, reason: String)
    /// Visor's Linux programs folder lacks one the container needs.
    case toolMissing(String)
    /// A Visor version that can't name a folder.
    case invalidVersion(String)

    public var description: String {
        switch self {
        case let .noContainersVolume(path):
            "There's no Containers volume at \(path). Make it with Visor Disk Utility, then try again."
        case let .checksumMismatch(what, expected, found):
            "\(what) isn't the one pinned: its SHA-256 is \(found), not \(expected)."
        case let .memberMissing(member):
            "The kernel's archive has no \(member)."
        case let .digestMismatch(what, expected, found):
            "\(what) isn't the image pinned: \(expected) is not among \(found.joined(separator: ", "))."
        case .noImagePinned:
            "No agent image is pinned: this Visor has no container.json, and Settings names no image digest."
        case let .toolRefused(name, reason):
            "Visor's Linux program \(name) is refused: \(reason)."
        case let .toolMissing(name):
            "Visor's Linux programs have no \(name)."
        case let .invalidVersion(version):
            "\"\(version)\" can't name a folder of Visor's Linux programs."
        }
    }

    public var errorDescription: String? { description }
}
