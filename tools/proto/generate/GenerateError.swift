/// Why the Swift couldn't be made (exit 2).
enum GenerateError: Error, CustomStringConvertible {
    /// The arguments aren't the tool's, or it wasn't run by Bazel.
    case usage(String)
    /// protoc failed: what it said.
    case protoc(String)

    var description: String {
        switch self {
        case .usage(let message), .protoc(let message): message
        }
    }
}
