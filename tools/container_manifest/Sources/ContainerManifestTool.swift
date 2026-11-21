import Foundation
import VisorContainerCore

/// Writes the container.json a release seals into Visor.app's
/// Contents/Resources (docs/containers.md): the agent image's digest, and
/// the kernel and init filesystem this commit's VisorContainerCore pins
/// (ContainerPins.current), so the file and the code that boots from it
/// always agree.
///
///     bazel run //tools/container_manifest -- --image <ghcr.io/attilathefun/visor-agent@sha256:… | sha256:…> --out <container.json>
///     bazel run //tools/container_manifest -- --workflow .github/workflows/ci.yml --out <container.json>
///
/// `--workflow` takes the image CI builds Visor's Linux programs in (the
/// linux-programs job's `container:`), the one reference by digest to
/// ghcr.io/attilathefun/visor-agent the file has; it refuses a file with
/// none, or with two different ones. Exits 0 once written, 2 otherwise.
@main
enum ContainerManifestTool {
    static func main() {
        do {
            let options = try ManifestOptions(Array(CommandLine.arguments.dropFirst()))
            let image = try options.image()
            let data = try ContainerManifest(image: image).encoded()
            try FileManager.default.createDirectory(at: options.out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: options.out, options: .atomic)
            print("container.json: \(image.reference()), kernel \(ContainerPins.current.kernel.sha256.prefix(12)), "
                  + "vminit \(ContainerPins.current.initfs.tag) (\(ContainerPins.current.initfs.digest.prefix(19))) -> \(options.out.path)")
        } catch {
            FileHandle.standardError.write(Data("container_manifest: \(error)\n".utf8))
            exit(2)
        }
    }
}
