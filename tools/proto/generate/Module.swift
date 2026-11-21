/// One SwiftPM module made from the protos: its name, the protos it is
/// made from, and how.
struct Module: Sendable {
    enum Kind: Sendable {
        /// The messages (protoc-gen-swift).
        case messages
        /// The services' servers or clients (protoc-gen-grpc-swift-2),
        /// importing the messages' module.
        case services(server: Bool)
    }

    let name: String
    let kind: Kind
    let protos: [String]

    /// Where the protos are, in the checkout; each named by its path under
    /// it, as they import each other.
    static let protoRoot = "protos"
    /// Where the modules' Swift is kept, in the checkout.
    static let sources = "libraries/visor_client_proto/Sources"

    static let messageProtos = ["commands", "rows", "server", "state"].map { "visor/client/v1/\($0).proto" }
    static let serviceProtos = ["visor/client/v1/services.proto"]

    static let messages = Module(name: "VisorClientProto", kind: .messages, protos: messageProtos)
    static let all = [
        messages,
        Module(name: "VisorClientGRPCServer", kind: .services(server: true), protos: serviceProtos),
        Module(name: "VisorClientGRPCClient", kind: .services(server: false), protos: serviceProtos),
    ]
}
