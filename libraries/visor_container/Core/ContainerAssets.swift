// The Sessions container's assets on the Containers volume
// (docs/containers.md): the kernel, the init filesystem and the agent
// image's root filesystem, each fetched once, checked against its pin
// (SHA-256 or digest), kept, and checked again before it's used.

import Foundation

public actor ContainerAssets {
    public nonisolated let layout: ContainerLayout
    public nonisolated let pins: ContainerPins
    /// The agent image: the release's (container.json) or Settings'; nil
    /// when neither pins one.
    public nonisolated let image: ImageDigest?
    private let backend: any ContainerAssetBackend
    private let log: @Sendable (String) -> Void
    /// The preparation under way, which a second caller waits for rather
    /// than fetching the same files beside it.
    private var preparing: Task<PreparedAssets, any Error>?

    public init(layout: ContainerLayout, image: ImageDigest?, pins: ContainerPins = .current,
                backend: any ContainerAssetBackend, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.layout = layout
        self.image = image
        self.pins = pins
        self.backend = backend
        self.log = log
    }

    /// The image a release pins, unless Settings names another digest.
    public static func image(manifest: ContainerManifest?, override: String?) -> ImageDigest? {
        if let override, let digest = ImageDigest(override) { return digest }
        return manifest?.image
    }

    /// What's there now, as files (nothing fetched or hashed).
    public nonisolated func status() -> ContainerAssetStatus {
        let files = FileManager.default
        let record = (try? Data(contentsOf: layout.kernelRecord)).flatMap { try? JSONDecoder().decode(KernelRecord.self, from: $0) }
        return ContainerAssetStatus(
            kernel: files.fileExists(atPath: layout.kernel.path) && record?.matches(pins.kernel) == true,
            initfs: files.fileExists(atPath: layout.initfs(digest: pins.initfs.digest).path),
            template: image.map { files.fileExists(atPath: layout.template(image: $0).path) },
            image: image)
    }

    /// Everything the container boots from: what's kept, checked, and what
    /// isn't, fetched.
    public func prepare() async throws -> PreparedAssets {
        if let preparing { return try await preparing.value }
        let task = Task { try await self.prepareAll() }
        preparing = task
        defer { preparing = nil }
        return try await task.value
    }

    private func prepareAll() async throws -> PreparedAssets {
        guard let image else { throw ContainerAssetsError.noImagePinned }
        let kernel = try await prepareKernel()
        let initfs = try await prepareInitfs()
        let template = try await prepareTemplate(image)
        return PreparedAssets(kernel: kernel, initfs: initfs, template: template, image: image)
    }

    // MARK: The kernel

    /// kernel/vmlinux: kept while its record names the pinned archive and
    /// its bytes hash to what was recorded; else the archive is fetched,
    /// checked by its SHA-256, and the kernel taken out of it.
    func prepareKernel() async throws -> URL {
        if let kept = try keptKernel() { return kept }
        let folder = layout.kernelFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let archive = folder.appendingPathComponent(".archive-\(token)")
        let partial = folder.appendingPathComponent(".vmlinux-\(token)")
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: partial)
        }
        log("container: fetching the kernel (\(pins.kernel.url.lastPathComponent))")
        try await backend.download(pins.kernel.url, to: archive)
        let found = try FileDigest.sha256(of: archive)
        guard found == pins.kernel.sha256 else {
            throw ContainerAssetsError.checksumMismatch(what: "The kernel's archive", expected: pins.kernel.sha256, found: found)
        }
        try await backend.extract(member: pins.kernel.member, from: archive, to: partial)
        let record = KernelRecord(url: pins.kernel.url, archiveSHA256: found, member: pins.kernel.member,
                                  sha256: try FileDigest.sha256(of: partial))
        try? FileManager.default.removeItem(at: layout.kernelRecord)
        try? FileManager.default.removeItem(at: layout.kernel)
        try FileManager.default.moveItem(at: partial, to: layout.kernel)
        try JSONEncoder().encode(record).write(to: layout.kernelRecord, options: .atomic)
        log("container: kernel at \(layout.kernel.path) (sha256 \(record.sha256))")
        return layout.kernel
    }

    /// The kept kernel, if it's the one pinned and unchanged.
    private func keptKernel() throws -> URL? {
        guard FileManager.default.fileExists(atPath: layout.kernel.path),
              let data = try? Data(contentsOf: layout.kernelRecord),
              let record = try? JSONDecoder().decode(KernelRecord.self, from: data),
              record.matches(pins.kernel) else { return nil }
        guard try FileDigest.sha256(of: layout.kernel) == record.sha256 else {
            log("container: the kept kernel's bytes changed; fetching it again")
            return nil
        }
        return layout.kernel
    }

    // MARK: The images

    /// The init filesystem of the pinned vminit, unpacked once.
    func prepareInitfs() async throws -> URL {
        let reference = pins.initfs.reference
        try await pulled(reference, digest: pins.initfs.digest, what: "The init filesystem's image")
        let destination = layout.initfs(digest: pins.initfs.digest)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        log("container: unpacking the init filesystem (vminit \(pins.initfs.tag))")
        try await unpacked(to: destination) { try await self.backend.unpackInitfs(reference, store: self.layout.store, to: $0) }
        return destination
    }

    /// The agent image's root filesystem, unpacked once.
    func prepareTemplate(_ image: ImageDigest) async throws -> URL {
        let reference = image.reference()
        try await pulled(reference, digest: image.value, what: "The agent image")
        let destination = layout.template(image: image)
        if FileManager.default.fileExists(atPath: destination.path) {
            // Its last use, for pruning templates no container has used.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        }
        log("container: unpacking \(reference) (\(ContainerPins.templateGiB) GiB)")
        let capacity = ContainerPins.templateGiB << 30
        try await unpacked(to: destination) {
            try await self.backend.unpackRootfs(reference, store: self.layout.store, to: $0, capacityBytes: capacity)
        }
        return destination
    }

    /// The image in the store (pulled if it isn't), refused unless it
    /// answers to the digest pinned.
    private func pulled(_ reference: String, digest: String, what: String) async throws {
        try FileManager.default.createDirectory(at: layout.store, withIntermediateDirectories: true)
        let digests = try await backend.pull(reference, store: layout.store)
        guard digests.contains(digest) else { throw ContainerAssetsError.digestMismatch(what: what, expected: digest, found: digests) }
    }

    /// A file unpacked beside its place and moved there once whole, so a
    /// file at the place is always a whole one.
    private func unpacked(to destination: URL, _ unpack: (URL) async throws -> Void) async throws {
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).partial-\(UUID().uuidString).ext4")
        defer { try? FileManager.default.removeItem(at: partial) }
        try await unpack(partial)
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}
