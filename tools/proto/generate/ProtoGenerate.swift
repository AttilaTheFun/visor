import Foundation

/// SwiftPM's copy of the client link's Swift (protos/visor/client/v1):
/// Bazel generates its own as it builds (swift_proto_library), and SwiftPM
/// builds the copy kept in libraries/visor_client_proto/Sources, which
/// this makes with the same protoc and plugins, run by Bazel:
///
///     bazel run //tools/proto:generate             # write it again
///     bazel run //tools/proto:generate -- --check  # exit 1 if it differs
///
/// Three modules: VisorClientProto (the messages, protoc-gen-swift), and
/// VisorClientGRPCServer and VisorClientGRPCClient (the services' servers
/// and clients, protoc-gen-grpc-swift-2), which import the first.
///
/// Exits 0 when the copy is written (or, checked, matches), 1 when the
/// check finds it differs, 2 when it couldn't be made.
@main
enum ProtoGenerate {
    static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            exit(try run(options) ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("generate: \(error)\n".utf8))
            exit(2)
        }
    }

    /// Makes every module's Swift in a folder of its own, then writes it
    /// over the copy kept, or compares the two. False when the check
    /// found them different.
    static func run(_ options: Options) throws -> Bool {
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("visor-proto-generate-\(getpid())")
        try? files.removeItem(at: scratch)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }

        let generator = Generator(options: options, scratch: scratch)
        var same = true
        for module in Module.all {
            let made = try generator.make(module)
            let kept = options.workspace.appendingPathComponent(Module.sources).appendingPathComponent(module.name)
            if options.check {
                let differences = try Tree.differences(made, kept)
                for difference in differences { print("\(module.name): \(difference)") }
                same = same && differences.isEmpty
            } else {
                try? files.removeItem(at: kept)
                try files.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.copyItem(at: made, to: kept)
                print("\(module.name): written")
            }
        }
        if options.check {
            print(same ? "The generated Swift matches the protos."
                : "\(Module.sources) differs from the protos: run `bazel run //tools/proto:generate`.")
        }
        return same
    }
}
