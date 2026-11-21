// What the Sessions container boots and runs, pinned (docs/containers.md):
// the kernel (Kata Containers' arm64 build, by its archive's SHA-256), the
// init filesystem (Containerization's vminit, by digest, of the package
// version built in), and the agent image's repository (its digest is the
// release's, in container.json, or Settings').

import Foundation

public struct ContainerPins: Codable, Equatable, Sendable {
    /// The Linux kernel: a member of a release archive, checked by the
    /// archive's SHA-256 before anything is taken out of it.
    public struct Kernel: Codable, Equatable, Sendable {
        /// The archive (`.tar.zst`).
        public var url: URL
        /// The archive's SHA-256, lowercase hex.
        public var sha256: String
        /// The kernel's path in the archive.
        public var member: String

        public init(url: URL, sha256: String, member: String) {
            self.url = url
            self.sha256 = sha256
            self.member = member
        }
    }

    /// Containerization's init filesystem (vminitd): the image's
    /// repository, the tag it was published as, and its index's digest,
    /// which is what's pulled.
    public struct InitFilesystem: Codable, Equatable, Sendable {
        public var repository: String
        public var tag: String
        public var digest: String

        public init(repository: String, tag: String, digest: String) {
            self.repository = repository
            self.tag = tag
            self.digest = digest
        }

        /// The reference pulled: by digest alone (a tag beside it would be
        /// what's resolved).
        public var reference: String { "\(repository)@\(digest)" }
    }

    public var kernel: Kernel
    public var initfs: InitFilesystem
    /// The Containerization version built in, which the init filesystem
    /// must match.
    public var containerization: String

    public init(kernel: Kernel, initfs: InitFilesystem, containerization: String) {
        self.kernel = kernel
        self.initfs = initfs
        self.containerization = containerization
    }

    /// The pins this build boots with: Kata Containers 3.32.0's arm64
    /// kernel (the bytes Shireworks boots), and vminit 0.57.0, the
    /// Containerization in third_party/swift_packages.
    public static let current = ContainerPins(
        kernel: Kernel(
            url: URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst")!,
            sha256: "8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5",
            member: "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug"),
        initfs: InitFilesystem(
            repository: "ghcr.io/apple/containerization/vminit",
            tag: "0.57.0",
            digest: "sha256:c30d5a14c9c25762005363c1736831608806ee8c2a9d8de70dd5439d4812e656"),
        containerization: "0.57.0")

    /// Visor's agent image, pulled by digest alone.
    public static let imageRepository = "ghcr.io/attilathefun/visor-agent"

    /// The size of the image's unpacked root filesystem (a sparse ext4
    /// file: only what's written takes room), in GiB.
    public static let templateGiB: UInt64 = 64
}
