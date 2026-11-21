import Foundation

/// What the tool is given: where protoc and the plugins are (Bazel passes
/// them, BUILD.bazel's `args`), the checkout, and whether to check rather
/// than write.
struct Options {
    static let usage = """
        usage: generate --protoc <path> --swift-plugin <path> --grpc-plugin <path> [--check]
          run by Bazel, which gives the paths: bazel run //tools/proto:generate [-- --check]
        """

    var protoc: URL
    var swiftPlugin: URL
    var grpcPlugin: URL
    /// Compare the copy kept with what the protos make, and write nothing.
    var check = false
    /// The checkout: `bazel run` says where it is, and starts the tool in
    /// its runfiles, where the paths it gives are relative to.
    var workspace: URL

    init(_ arguments: [String]) throws {
        var paths: [String: URL] = [:]
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--check":
                check = true
            case "--protoc", "--swift-plugin", "--grpc-plugin":
                guard let value = rest.popFirst() else { throw GenerateError.usage("\(argument) takes a path\n\(Self.usage)") }
                paths[argument] = value.hasPrefix("/") ? URL(fileURLWithPath: value) : here.appendingPathComponent(value).standardizedFileURL
            default:
                throw GenerateError.usage("unknown argument \(argument)\n\(Self.usage)")
            }
        }
        guard let protoc = paths["--protoc"], let swiftPlugin = paths["--swift-plugin"], let grpcPlugin = paths["--grpc-plugin"] else {
            throw GenerateError.usage(Self.usage)
        }
        guard let workspace = ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] else {
            throw GenerateError.usage("no BUILD_WORKSPACE_DIRECTORY: run it with `bazel run`\n\(Self.usage)")
        }
        self.protoc = protoc
        self.swiftPlugin = swiftPlugin
        self.grpcPlugin = grpcPlugin
        self.workspace = URL(fileURLWithPath: workspace)
    }
}
