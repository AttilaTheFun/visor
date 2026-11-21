// A ContainerAssetBackend with no network: the kernel's archive is bytes
// given, its member another's, an image answers to the digests given, and
// unpacking writes a small file. It counts what it was asked.

import Foundation
import VisorContainerCore

actor FakeBackend: ContainerAssetBackend {
    var archive: Data
    var member: String
    var kernel: Data
    var digests: [String: [String]]
    private(set) var downloads = 0
    private(set) var pulls: [String] = []
    private(set) var unpacks: [String] = []

    init(archive: Data = Data("kata archive".utf8), member: String = ContainerPins.current.kernel.member,
         kernel: Data = Data("vmlinux".utf8), digests: [String: [String]] = [:]) {
        self.archive = archive
        self.member = member
        self.kernel = kernel
        self.digests = digests
    }

    func setDigests(_ reference: String, _ answer: [String]) { digests[reference] = answer }

    func download(_ url: URL, to destination: URL) async throws {
        downloads += 1
        try archive.write(to: destination)
    }

    func extract(member: String, from archive: URL, to destination: URL) async throws {
        guard member == self.member else { throw ContainerAssetsError.memberMissing(member) }
        try kernel.write(to: destination)
    }

    func pull(_ reference: String, store: URL) async throws -> [String] {
        pulls.append(reference)
        return digests[reference] ?? []
    }

    func unpackInitfs(_ reference: String, store: URL, to destination: URL) async throws {
        unpacks.append(reference)
        try Data("initfs".utf8).write(to: destination)
    }

    func unpackRootfs(_ reference: String, store: URL, to destination: URL, capacityBytes: UInt64) async throws {
        unpacks.append(reference)
        try Data("rootfs \(capacityBytes)".utf8).write(to: destination)
    }
}
