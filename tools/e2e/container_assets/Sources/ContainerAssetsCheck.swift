import DiskVolumes
import Foundation
import VisorContainer
import VisorContainerCore

/// The Sessions container's assets fetched for real (docs/containers.md):
/// Kata's kernel (its archive checked by SHA-256), Containerization's vminit
/// (by digest) unpacked to the init filesystem, and Visor's agent image (by
/// digest) unpacked to its template, then fetched again to show each is kept
/// and checked rather than fetched twice. None of it needs Virtualization,
/// so it runs in a macOS VM lease; booting is the container engine's.
///
///     bazel run //tools/e2e/container_assets -- --image <ghcr.io/attilathefun/visor-agent@sha256:…> [--root <folder>]
///         [--linux <Visor.app/Contents/Resources/Linux> --version <visor version>]
///
/// `--root` is where the Containers folder would be on the Visor volume (a
/// scratch folder where there's no volume); without it, the volume's, or it
/// refuses with Visor Disk Utility's name. `--linux` stages Visor's Linux
/// programs there too, under the link rule. Exits 0 when everything was had
/// and checked, 1 when something failed, 2 for the arguments.
@main
enum ContainerAssetsCheck {
    static func main() async {
        var image: ImageDigest?
        var root: URL?
        var linux: URL?
        var version: String?
        var rest = CommandLine.arguments.dropFirst()
        while let argument = rest.popFirst() {
            guard let value = rest.popFirst() else { usage("\(argument) takes a value") }
            switch argument {
            case "--image":
                guard let digest = ImageDigest(value) else { usage("\(value) isn't an image by digest") }
                image = digest
            case "--root": root = URL(fileURLWithPath: value, isDirectory: true)
            case "--linux": linux = URL(fileURLWithPath: value, isDirectory: true)
            case "--version": version = value
            default: usage("unknown argument \(argument)")
            }
        }
        guard let image else { usage("--image is needed") }
        do {
            let layout: ContainerLayout
            if let root {
                layout = ContainerLayout(root: root)
            } else {
                layout = try ContainerLayout.locate(DiskVolumes.locate(dataDirectory: VisorFolders.locate().data))
            }
            say("host: \(ContainerHost.current)")
            say("root: \(layout.root.path)")
            for round in 1...2 {
                let started = Date()
                let assets = ContainerAssets(layout: layout, image: image, backend: ContainerizationBackend(), log: { say($0) })
                say("round \(round): before, \(assets.status())")
                let prepared = try await assets.prepare()
                say("round \(round): \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                for file in [prepared.kernel, prepared.initfs, prepared.template] { say("  \(describe(file))") }
                guard assets.status().isComplete else {
                    say("failed: prepared, but the status says \(assets.status().missing) are missing")
                    exit(1)
                }
            }
            if let linux {
                guard let version else { usage("--linux needs --version") }
                let staged = try ToolsFolder.stage(from: linux, layout: layout, version: version)
                try ToolsFolder.check(staged)
                say("tools: \(staged.path): \(try FileManager.default.contentsOfDirectory(atPath: staged.path).sorted())")
            }
            say("ok")
        } catch {
            say("failed: \(error)")
            exit(1)
        }
    }

    /// A file's path, its size, and what of it is on the disk (a template is sparse).
    static func describe(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        let gb = { (bytes: Int?) in String(format: "%.2f GB", Double(bytes ?? 0) / 1e9) }
        return "\(url.path): \(gb(values?.fileSize)), \(gb(values?.totalFileAllocatedSize)) on disk"
    }

    static func say(_ line: String) { print(line) }

    static func usage(_ problem: String) -> Never {
        FileHandle.standardError.write(Data("container_assets: \(problem)\nusage: container_assets --image <reference by digest> [--root <folder>] [--linux <folder> --version <v>]\n".utf8))
        exit(2)
    }
}
