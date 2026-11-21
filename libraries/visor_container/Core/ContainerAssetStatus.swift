// Which of the container's assets are on the Visor volume (Containers/) now, as
// files: nothing fetched or hashed to say so (preparing them checks each).

public struct ContainerAssetStatus: Equatable, Sendable {
    /// The kernel, recorded as the one pinned.
    public var kernel: Bool
    /// The init filesystem of the pinned vminit.
    public var initfs: Bool
    /// The agent image's root filesystem; nil when no image is pinned.
    public var template: Bool?
    /// The image pinned, if any.
    public var image: ImageDigest?

    public init(kernel: Bool, initfs: Bool, template: Bool?, image: ImageDigest?) {
        self.kernel = kernel
        self.initfs = initfs
        self.template = template
        self.image = image
    }

    /// Everything there: the container could boot from it.
    public var isComplete: Bool { kernel && initfs && template == true }

    /// What isn't there, for a person.
    public var missing: [String] {
        var names: [String] = []
        if !kernel { names.append("the kernel") }
        if !initfs { names.append("the init filesystem") }
        switch template {
        case nil: names.append("an image pin")
        case false?: names.append("the image's root filesystem")
        case true?: break
        }
        return names
    }
}
