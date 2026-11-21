// ContainerAssets' fetching and unpacking on a Mac: the kernel's archive
// over URLSession and taken apart with Containerization's ArchiveReader
// (zstd), images pulled into Containerization's ImageStore, the init
// filesystem made by InitImage, and the agent image's root filesystem by
// EXT4Unpacker. None of it needs Virtualization: it runs in a macOS VM too.

import Containerization
import ContainerizationArchive
import ContainerizationOCI
import Foundation
import VisorContainerCore

public actor ContainerizationBackend: ContainerAssetBackend {
    /// One store per folder, kept: two over the same folder would each
    /// keep its own references.
    private var stores: [URL: ImageStore] = [:]

    public init() {}

    /// Apple silicon's Linux: what the container runs.
    static let platform = ContainerizationOCI.Platform(arch: "arm64", os: "linux")

    public func download(_ url: URL, to destination: URL) async throws {
        let (file, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: file)
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "\(url) answered \(http.statusCode)"])
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }

    public func extract(member: String, from archive: URL, to destination: URL) async throws {
        let reader = try ArchiveReader(file: archive)
        guard let (_, data) = try? reader.extractFile(path: member) else { throw ContainerAssetsError.memberMissing(member) }
        try data.write(to: destination)
    }

    public func pull(_ reference: String, store: URL) async throws -> [String] {
        let image = try await self.store(store).get(reference: reference, pull: true)
        var digests = [image.digest]
        // An image pushed as one manifest is kept under an index the store
        // made for it: the manifest's digest is the one pinned.
        if let index = try? await image.index() { digests += index.manifests.map(\.digest) }
        return digests
    }

    public func unpackInitfs(_ reference: String, store: URL, to destination: URL) async throws {
        let image = try await self.store(store).get(reference: reference)
        _ = try await InitImage(image: image).initBlock(at: destination, for: .linuxArm)
    }

    public func unpackRootfs(_ reference: String, store: URL, to destination: URL, capacityBytes: UInt64) async throws {
        let image = try await self.store(store).get(reference: reference)
        _ = try await EXT4Unpacker(capacityInBytes: capacityBytes).unpack(image, for: Self.platform, at: destination)
    }

    /// The image's own process settings (its environment, working folder,
    /// user), linux/arm64's; nil when it has none.
    func imageConfig(_ reference: String, store: URL) async throws -> ImageConfig? {
        let image = try await self.store(store).get(reference: reference)
        return try await image.config(for: Self.platform).config
    }

    private func store(_ folder: URL) throws -> ImageStore {
        let key = folder.standardizedFileURL
        if let kept = stores[key] { return kept }
        let made = try ImageStore(path: key)
        stores[key] = made
        return made
    }
}
