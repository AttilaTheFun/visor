import Foundation

/// Runs protoc for each module, into a scratch folder.
struct Generator {
    let options: Options
    let scratch: URL

    /// The module's Swift, made: the folder it is in.
    func make(_ module: Module) throws -> URL {
        let out = scratch.appendingPathComponent(module.name)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var arguments = ["-I", options.workspace.appendingPathComponent(Module.protoRoot).path]
        switch module.kind {
        case .messages:
            arguments += ["--plugin=protoc-gen-swift=\(options.swiftPlugin.path)",
                          "--swift_opt=Visibility=Public", "--swift_out=\(out.path)"]
        case .services(let server):
            let mappings = try writeMappings()
            let grpcOptions = ["Visibility=Public", "Server=\(server)", "Client=\(!server)", "ProtoPathModuleMappings=\(mappings.path)"]
            arguments += ["--plugin=protoc-gen-grpc-swift-2=\(options.grpcPlugin.path)",
                          "--grpc-swift-2_opt=\(grpcOptions.joined(separator: ","))", "--grpc-swift-2_out=\(out.path)"]
        }
        arguments += module.protos
        let process = Process()
        process.executableURL = options.protoc
        process.arguments = arguments
        // The protos named by their path under the root, as they import
        // each other.
        process.currentDirectoryURL = options.workspace.appendingPathComponent(Module.protoRoot)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GenerateError.protoc("protoc failed for \(module.name) (status \(process.terminationStatus)):\n\(said)")
        }
        return out
    }

    /// Which module each message proto's Swift is in, as the gRPC plugin
    /// reads it (SwiftProtobuf's ModuleMappings, as text), so the services'
    /// Swift imports the messages' module.
    private func writeMappings() throws -> URL {
        let file = scratch.appendingPathComponent("module_mappings.asciipb")
        let paths = Module.messages.protos.map { "  proto_file_path: \"\($0)\"" }.joined(separator: "\n")
        let text = "mapping {\n  module_name: \"\(Module.messages.name)\"\n\(paths)\n}\n"
        try Data(text.utf8).write(to: file)
        return file
    }
}
