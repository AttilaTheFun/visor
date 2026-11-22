// The pins, container.json, image digests, and where things go on the
// Visor volume.

import DiskVolumes
import Foundation
import Testing
import VisorContainerCore

@Suite struct PinsTests {
    static let hex = String(repeating: "0123456789abcdef", count: 4)

    @Test func theKernelIsKatas3320Arm64ByItsArchivesSHA() {
        let kernel = ContainerPins.current.kernel
        #expect(kernel.url.absoluteString == "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst")
        #expect(kernel.sha256 == "8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5")
        #expect(kernel.member.hasPrefix("opt/kata/share/kata-containers/vmlinux-"))
    }

    @Test func theInitFilesystemIsTheBuiltInContainerizationsVersion() {
        let pins = ContainerPins.current
        #expect(pins.initfs.tag == pins.containerization)
        #expect(pins.initfs.reference == "ghcr.io/apple/containerization/vminit@\(pins.initfs.digest)")
        #expect(ImageDigest(pins.initfs.digest) != nil)
    }

    @Test func aDigestIsSHA256AndNothingElse() {
        #expect(ImageDigest("sha256:\(Self.hex)")?.value == "sha256:\(Self.hex)")
        #expect(ImageDigest("ghcr.io/attilathefun/visor-agent@sha256:\(Self.hex)")?.hex == Self.hex)
        #expect(ImageDigest("  sha256:\(Self.hex)\n")?.short == "0123456789ab")
        #expect(ImageDigest("ghcr.io/attilathefun/visor-agent:0.63") == nil, "a tag can move")
        #expect(ImageDigest("ghcr.io/someone/else@sha256:\(Self.hex)") == nil, "another repository")
        #expect(ImageDigest("sha256:\(Self.hex.uppercased())") == nil)
        #expect(ImageDigest("sha256:\(Self.hex.dropLast())") == nil)
        #expect(ImageDigest("sha512:\(Self.hex)\(Self.hex)") == nil)
        #expect(ImageDigest(String(repeating: "a", count: 64)) == nil)
    }

    @Test func containerJSONRoundTripsWithTheImageAsAReference() throws {
        let manifest = ContainerManifest(image: try #require(ImageDigest("sha256:\(Self.hex)")))
        let text = String(decoding: try manifest.encoded(), as: UTF8.self)
        #expect(text.contains(#""image" : "ghcr.io/attilathefun/visor-agent@sha256:\#(Self.hex)""#))
        #expect(text.contains(#""digest" : "sha256:c30d5a14c9c25762005363c1736831608806ee8c2a9d8de70dd5439d4812e656""#))
        #expect(text.contains(#""url" : "https://github.com/kata-containers/"#))
        #expect(try ContainerManifest.decoded(from: manifest.encoded()) == manifest)
    }

    @Test func containerJSONOfALaterVersionOrATaggedImageIsRefused() throws {
        var later = try JSONSerialization.jsonObject(with: ContainerManifest(image: ImageDigest("sha256:\(Self.hex)")!).encoded()) as! [String: Any]
        later["version"] = 2
        #expect(throws: (any Error).self) { try ContainerManifest.decoded(from: JSONSerialization.data(withJSONObject: later)) }
        var tagged = later
        tagged["version"] = 1
        tagged["image"] = "ghcr.io/attilathefun/visor-agent:latest"
        #expect(throws: (any Error).self) { try ContainerManifest.decoded(from: JSONSerialization.data(withJSONObject: tagged)) }
    }

    @Test func theAppsContainerJSONIsReadFromItsResources() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("resources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ContainerManifest.inResources(folder) == nil)
        let manifest = ContainerManifest(image: ImageDigest("sha256:\(Self.hex)")!)
        try manifest.encoded().write(to: folder.appendingPathComponent("container.json"))
        #expect(ContainerManifest.inResources(folder) == manifest)
    }

    @Test func theLayoutIsTheContainersFolderOnVisor() throws {
        let mounted = DiskVolumes(sessions: LocatedVolume(role: .sessions, path: "/Volumes/Sessions", isMounted: true, record: nil),
                                  sources: LocatedVolume(role: .sources, path: "/Volumes/Sources", isMounted: true, record: nil),
                                  visor: LocatedVolume(role: .visor, path: "/Volumes/Visor", isMounted: true, record: nil),
                                  status: nil)
        let layout = try ContainerLayout.locate(mounted)
        #expect(layout.root.path == "/Volumes/Visor/Containers")
        #expect(layout.kernel.path == "/Volumes/Visor/Containers/kernel/vmlinux")
        #expect(layout.store.path == "/Volumes/Visor/Containers/store")
        #expect(layout.templates.path == "/Volumes/Visor/Containers/templates")
        #expect(layout.tools(version: "0.64.3")?.path == "/Volumes/Visor/Containers/tools/0.64.3")
        for bad in ["", ".", "..", "../x", "a/b"] { #expect(layout.tools(version: bad) == nil) }
    }

    @Test func noVisorVolumeIsRefusedWithAPointerToDiskUtility() {
        let missing = DiskVolumes(sessions: LocatedVolume(role: .sessions, path: "/Volumes/Sessions", isMounted: true, record: nil),
                                  sources: LocatedVolume(role: .sources, path: "/Volumes/Sources", isMounted: false, record: nil),
                                  visor: LocatedVolume(role: .visor, path: "/Volumes/Visor", isMounted: false, record: nil),
                                  status: nil)
        #expect(throws: ContainerAssetsError.noVisorVolume("/Volumes/Visor")) { try ContainerLayout.locate(missing) }
        #expect(ContainerAssetsError.noVisorVolume("/Volumes/Visor").description.contains("Visor Disk Utility"))
    }
}
