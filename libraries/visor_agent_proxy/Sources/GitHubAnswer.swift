import Foundation

/// GitHub's answer to one of the checks' reads: its status, and its body as
/// JSON (nil when it isn't, or none came: status 0).
struct GitHubAnswer: Equatable, Sendable {
    var status: Int
    var json: GateJSON?

    var ok: Bool { (200..<300).contains(status) }

    subscript(_ path: String...) -> GateJSON? {
        var value = json
        for key in path { value = value?.object?[key] }
        return value
    }
}
