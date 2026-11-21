// What the container boots from, each checked against its pin.

import Foundation

public struct PreparedAssets: Equatable, Sendable {
    /// kernel/vmlinux.
    public var kernel: URL
    /// The init filesystem (ext4, mounted read-only as /).
    public var initfs: URL
    /// The agent image's root filesystem, which each start clones.
    public var template: URL
    public var image: ImageDigest

    public init(kernel: URL, initfs: URL, template: URL, image: ImageDigest) {
        self.kernel = kernel
        self.initfs = initfs
        self.template = template
        self.image = image
    }
}
