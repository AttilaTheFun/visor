// container.json: what a release pins for the Sessions container, in
// Visor.app's Contents/Resources (written at release by
// //tools/container_manifest: tools/release_mac.sh,
// tools/ci/mac_app_linux_programs.sh). The image's digest is the release's;
// the kernel and init filesystem are the build's own (ContainerPins), kept
// beside it so the file says everything the container boots.

import Foundation

public struct ContainerManifest: Codable, Equatable, Sendable {
    public static let fileName = "container.json"
    /// The file's format; a reader refuses a later one.
    public static let currentVersion = 1

    public var version: Int
    /// Visor's agent image, by digest.
    public var image: ImageDigest
    public var pins: ContainerPins

    public init(version: Int = Self.currentVersion, image: ImageDigest, pins: ContainerPins = .current) {
        self.version = version
        self.image = image
        self.pins = pins
    }

    private enum CodingKeys: String, CodingKey {
        case version, image, kernel, initfs, containerization
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "container.json version \(version) is later than this Visor reads")
        }
        image = try c.decode(ImageDigest.self, forKey: .image)
        pins = ContainerPins(kernel: try c.decode(ContainerPins.Kernel.self, forKey: .kernel),
                             initfs: try c.decode(ContainerPins.InitFilesystem.self, forKey: .initfs),
                             containerization: try c.decode(String.self, forKey: .containerization))
    }

    /// The image as a full reference (`ghcr.io/attilathefun/visor-agent@sha256:…`).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(image.reference(), forKey: .image)
        try c.encode(pins.kernel, forKey: .kernel)
        try c.encode(pins.initfs, forKey: .initfs)
        try c.encode(pins.containerization, forKey: .containerization)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decoded(from data: Data) throws -> ContainerManifest {
        try JSONDecoder().decode(ContainerManifest.self, from: data)
    }

    /// The app's own: `<resources>/container.json`; nil when there's none
    /// (a build to run here, not a release's) or it can't be read.
    public static func inResources(_ resources: URL?) -> ContainerManifest? {
        guard let resources, let data = try? Data(contentsOf: resources.appendingPathComponent(fileName)) else { return nil }
        return try? decoded(from: data)
    }
}
