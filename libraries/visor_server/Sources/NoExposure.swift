import Foundation

/// No road at all: a server reached on loopback only (a staging server).
final class NoExposure: ServerExposure {
    let title = "Loopback"
    let installed = false
    func address() async -> String? { nil }
    func identity() async -> String? { nil }
    func requester(headers: [String: String]) -> String? { nil }
    func fronts(port: UInt16) async -> Bool { false }
    func front(port: UInt16) async -> String { "" }
}
