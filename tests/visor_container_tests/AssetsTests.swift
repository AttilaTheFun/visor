// ContainerAssets against a fake backend: where each asset goes, that each
// is refused unless it's the one pinned, and that what's kept is used
// again without fetching it.

import Crypto
import Foundation
import Testing
import VisorContainerCore

@Suite struct AssetsTests {
    static let image = ImageDigest("sha256:" + String(repeating: "ab", count: 32))!
    static let archive = Data("kata archive".utf8)

    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The current pins, with the kernel's archive the fake's.
    static func pins(archiveSHA256: String = hex(archive)) -> ContainerPins {
        var pins = ContainerPins.current
        pins.kernel.sha256 = archiveSHA256
        return pins
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("container-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A backend whose images answer to their pins.
    private func backend() async -> FakeBackend {
        let backend = FakeBackend(archive: Self.archive)
        await backend.setDigests(ContainerPins.current.initfs.reference, ["sha256:index", ContainerPins.current.initfs.digest])
        // Pushed as one manifest: the store's own index first, the manifest's digest beside it.
        await backend.setDigests(Self.image.reference(), ["sha256:" + String(repeating: "0", count: 64), Self.image.value])
        return backend
    }

    @Test func theAssetsGoWhereTheLayoutSays() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ContainerLayout(root: root)
        let assets = ContainerAssets(layout: layout, image: Self.image, pins: Self.pins(), backend: await backend())
        #expect(assets.status() == ContainerAssetStatus(kernel: false, initfs: false, template: false, image: Self.image))
        let prepared = try await assets.prepare()
        #expect(prepared.kernel.path == root.path + "/kernel/vmlinux")
        #expect(prepared.initfs.path == root.path + "/store/initfs/c30d5a14c9c25762005363c1736831608806ee8c2a9d8de70dd5439d4812e656.ext4")
        #expect(prepared.template.path == root.path + "/templates/\(Self.image.hex)-64.ext4")
        #expect(try Data(contentsOf: prepared.kernel) == Data("vmlinux".utf8))
        #expect(try String(contentsOf: prepared.template, encoding: .utf8) == "rootfs \(UInt64(64) << 30)")
        #expect(assets.status().isComplete)
        // Nothing half-made is left beside them.
        for folder in [layout.kernelFolder, layout.templates, layout.store.appendingPathComponent("initfs")] {
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix(".") })
        }
    }

    @Test func whatsKeptIsUsedAgainWithoutFetching() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = await backend()
        let layout = ContainerLayout(root: root)
        _ = try await ContainerAssets(layout: layout, image: Self.image, pins: Self.pins(), backend: backend).prepare()
        _ = try await ContainerAssets(layout: layout, image: Self.image, pins: Self.pins(), backend: backend).prepare()
        #expect(await backend.downloads == 1)
        #expect(await backend.unpacks.count == 2)
        // Each image is looked for in the store each time (the store pulls only what it hasn't).
        #expect(await backend.pulls.count == 4)
    }

    @Test func aKernelArchiveOfAnotherSHAIsRefused() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = ContainerAssets(layout: ContainerLayout(root: root), image: Self.image,
                                     pins: Self.pins(archiveSHA256: String(repeating: "f", count: 64)), backend: await backend())
        await #expect(throws: ContainerAssetsError.checksumMismatch(what: "The kernel's archive", expected: String(repeating: "f", count: 64),
                                                                     found: Self.hex(Self.archive))) {
            try await assets.prepare()
        }
        #expect(!FileManager.default.fileExists(atPath: root.path + "/kernel/vmlinux"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path + "/kernel").isEmpty)
    }

    @Test func anArchiveWithoutTheKernelIsRefused() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var pins = Self.pins()
        pins.kernel.member = "opt/kata/share/kata-containers/vmlinux-other"
        let assets = ContainerAssets(layout: ContainerLayout(root: root), image: Self.image, pins: pins, backend: await backend())
        await #expect(throws: ContainerAssetsError.memberMissing("opt/kata/share/kata-containers/vmlinux-other")) { try await assets.prepare() }
    }

    @Test func aKeptKernelWhoseBytesChangedIsFetchedAgain() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = await backend()
        let layout = ContainerLayout(root: root)
        _ = try await ContainerAssets(layout: layout, image: Self.image, pins: Self.pins(), backend: backend).prepare()
        try Data("tampered".utf8).write(to: layout.kernel)
        _ = try await ContainerAssets(layout: layout, image: Self.image, pins: Self.pins(), backend: backend).prepare()
        #expect(await backend.downloads == 2)
        #expect(try Data(contentsOf: layout.kernel) == Data("vmlinux".utf8))
    }

    @Test func aKernelRecordedForAnotherPinIsntCounted() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ContainerLayout(root: root)
        _ = try await ContainerAssets(layout: layout, image: Self.image, pins: Self.pins(), backend: await backend()).prepare()
        let other = ContainerAssets(layout: layout, image: Self.image, pins: Self.pins(archiveSHA256: String(repeating: "e", count: 64)),
                                    backend: await backend())
        #expect(!other.status().kernel)
    }

    @Test func anImageOfAnotherDigestIsRefused() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = await backend()
        await backend.setDigests(Self.image.reference(), ["sha256:" + String(repeating: "1", count: 64)])
        let assets = ContainerAssets(layout: ContainerLayout(root: root), image: Self.image, pins: Self.pins(), backend: backend)
        await #expect(throws: ContainerAssetsError.self) { try await assets.prepare() }
        #expect(!FileManager.default.fileExists(atPath: ContainerLayout(root: root).template(image: Self.image).path))
    }

    @Test func theInitFilesystemIsPulledByDigestAlone() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = await backend()
        _ = try await ContainerAssets(layout: ContainerLayout(root: root), image: Self.image, pins: Self.pins(), backend: backend).prepare()
        #expect(await backend.pulls.first == "ghcr.io/apple/containerization/vminit@sha256:c30d5a14c9c25762005363c1736831608806ee8c2a9d8de70dd5439d4812e656")
        #expect(await backend.pulls.last == "ghcr.io/attilathefun/visor-agent@\(Self.image.value)")
    }

    @Test func noImagePinnedIsSaid() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = ContainerAssets(layout: ContainerLayout(root: root), image: nil, pins: Self.pins(), backend: await backend())
        #expect(assets.status().template == nil)
        #expect(assets.status().missing.contains("an image pin"))
        await #expect(throws: ContainerAssetsError.noImagePinned) { try await assets.prepare() }
    }

    @Test func settingsDigestStandsInForTheReleases() throws {
        let manifest = ContainerManifest(image: Self.image)
        let other = "sha256:" + String(repeating: "cd", count: 32)
        #expect(ContainerAssets.image(manifest: manifest, override: nil) == Self.image)
        #expect(ContainerAssets.image(manifest: manifest, override: other)?.value == other)
        #expect(ContainerAssets.image(manifest: manifest, override: "latest") == Self.image)
        #expect(ContainerAssets.image(manifest: nil, override: nil) == nil)
    }
}
