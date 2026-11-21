import Foundation
import VisorContainerCore

/// What the tool is asked: the image (given, or found in a workflow file)
/// and where container.json goes.
struct ManifestOptions {
    static let usage = """
        usage: container_manifest (--image <reference or digest> | --workflow <ci.yml>) --out <container.json>
          --image     ghcr.io/attilathefun/visor-agent@sha256:…, or sha256:…
          --workflow  a workflow file naming the image by digest once (CI's linux-programs job's container)
          --out       where container.json is written
        """

    enum Source {
        case image(String)
        case workflow(URL)
    }

    var source: Source
    var out: URL

    /// The arguments after the program's name. A relative path is the
    /// caller's: `bazel run` starts the tool in its runfiles, and says
    /// where it was run from in BUILD_WORKING_DIRECTORY.
    init(_ arguments: [String]) throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BUILD_WORKING_DIRECTORY"] ?? FileManager.default.currentDirectoryPath,
                       isDirectory: true)
        func path(_ text: String) -> URL { text.hasPrefix("/") ? URL(fileURLWithPath: text) : base.appendingPathComponent(text).standardizedFileURL }
        var source: Source?
        var out: URL?
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            guard ["--image", "--workflow", "--out"].contains(argument) else {
                throw ManifestToolError(argument == "-h" || argument == "--help" ? Self.usage : "unknown argument \(argument)\n\(Self.usage)")
            }
            guard let value = rest.popFirst() else { throw ManifestToolError("\(argument) takes a value\n\(Self.usage)") }
            switch argument {
            case "--out": out = path(value)
            default:
                guard source == nil else { throw ManifestToolError("--image or --workflow, once\n\(Self.usage)") }
                source = argument == "--image" ? .image(value) : .workflow(path(value))
            }
        }
        guard let source, let out else { throw ManifestToolError(Self.usage) }
        self.source = source
        self.out = out
    }

    /// The image's digest, from the argument or the workflow file.
    func image() throws -> ImageDigest {
        switch source {
        case let .image(text):
            guard let digest = ImageDigest(text) else {
                throw ManifestToolError("\(text) isn't \(ContainerPins.imageRepository)@sha256:… or sha256:… (a tag is never pinned)")
            }
            return digest
        case let .workflow(file):
            return try Self.image(inWorkflow: String(contentsOf: file, encoding: .utf8), named: file.path)
        }
    }

    /// The one digest of the agent image a workflow file names.
    static func image(inWorkflow text: String, named name: String) throws -> ImageDigest {
        let prefix = ContainerPins.imageRepository + "@"
        var found = Set<ImageDigest>()
        var rest = Substring(text)
        while let range = rest.range(of: prefix) {
            let digest = rest[range.lowerBound...].prefix { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
            if let parsed = ImageDigest(String(digest)) { found.insert(parsed) }
            rest = rest[range.upperBound...]
        }
        guard found.count == 1, let image = found.first else {
            throw ManifestToolError("\(name) names \(found.count) digests of \(ContainerPins.imageRepository), not one: give --image")
        }
        return image
    }
}
