// This Mac as VisorContainer reads it (macOS alone): its version, chip and
// memory, whatever kind of Mac runs the tests (a macOS VM can't nest, so
// virtualization isn't asserted).

import Foundation
import Testing
import VisorContainer
import VisorContainerCore

@Suite struct HostTests {
    @Test func thisMacIsRead() {
        let host = ContainerHost.current
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #expect(host.systemVersion.hasPrefix("\(version.majorVersion).\(version.minorVersion)"))
        #expect(host.isMacOS26OrLater == (version.majorVersion >= 26))
        #if arch(arm64)
        #expect(host.isAppleSilicon)
        #endif
        if !host.virtualizationSupported { #expect(!host.canRunContainer) }
    }

    @Test func freeMemoryIsAtMostAllOfIt() throws {
        let available = try #require(HostMemory.availableBytes)
        #expect(available > 0)
        #expect(available <= HostMemory.physicalBytes)
    }

    @Test func anArchiveWithoutTheMemberSaysSo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A tar of one file, made by the system's tar.
        try Data("hello".utf8).write(to: folder.appendingPathComponent("hello.txt"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-c", "-f", folder.appendingPathComponent("a.tar").path, "-C", folder.path, "hello.txt"]
        try tar.run()
        tar.waitUntilExit()
        let backend = ContainerizationBackend()
        let out = folder.appendingPathComponent("out")
        try await backend.extract(member: "hello.txt", from: folder.appendingPathComponent("a.tar"), to: out)
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello")
        await #expect(throws: ContainerAssetsError.memberMissing("vmlinux")) {
            try await backend.extract(member: "vmlinux", from: folder.appendingPathComponent("a.tar"), to: folder.appendingPathComponent("none"))
        }
    }
}
