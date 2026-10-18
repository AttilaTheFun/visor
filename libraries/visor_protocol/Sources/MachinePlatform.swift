#if canImport(Foundation)
import Foundation
#endif

/// A kind of virtual machine a server can run an agent's session in.
public enum MachinePlatform: String, Codable, CaseIterable, Sendable {
    /// macOS, with Xcode, Bazel and Homebrew. Apple lets a Mac run two at
    /// once.
    case macos
    /// Ubuntu with a desktop, apt, Bazel and git.
    case linux

    public var title: String {
        switch self {
        case .macos: "macOS"
        case .linux: "Linux"
        }
    }

    /// The most a host may run at once, where the system sets one (Apple's
    /// two macOS machines per Mac).
    public var hostLimit: Int? {
        switch self {
        case .macos: 2
        case .linux: nil
        }
    }
}
