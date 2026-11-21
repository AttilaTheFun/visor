// What ContainerAssets needs done that touches the network or an image's
// bytes: VisorContainer's ContainerizationBackend on a Mac (URLSession,
// Containerization's ImageStore, ArchiveReader and EXT4Unpacker), a fake in
// the tests. ContainerAssets decides what's fetched, where it goes and
// whether it's the one pinned.

import Foundation

public protocol ContainerAssetBackend: Sendable {
    /// Downloads `url` into a new file at `destination`.
    func download(_ url: URL, to destination: URL) async throws

    /// Writes the archive's `member` to a new file at `destination`; throws
    /// ContainerAssetsError.memberMissing when it has none.
    func extract(member: String, from archive: URL, to destination: URL) async throws

    /// The image of `reference`, pulled into the image store at `store` if
    /// it isn't there: the digests it answers to (its index's, and each
    /// manifest's).
    func pull(_ reference: String, store: URL) async throws -> [String]

    /// The init filesystem of `reference` (in the store) unpacked to a new
    /// file at `destination`.
    func unpackInitfs(_ reference: String, store: URL, to destination: URL) async throws

    /// The image's root filesystem (linux/arm64) unpacked to a new ext4
    /// file at `destination` of at least `capacityBytes`.
    func unpackRootfs(_ reference: String, store: URL, to destination: URL, capacityBytes: UInt64) async throws
}
