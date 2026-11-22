// A filesystem and a keychain made up for the plan: paths and their text,
// services and their accounts.

import Foundation
import VisorUninstall

struct FakeFiles: UninstallFiles {
    /// Every path there, a file's text or nil for a folder.
    var paths: [String: String?]

    init(_ paths: [String: String?]) { self.paths = paths }

    func exists(_ path: String) -> Bool {
        paths[path] != nil || paths.keys.contains { $0.hasPrefix(path + "/") }
    }

    func contents(ofFolder path: String) -> [String] {
        let prefix = path + "/"
        return Array(Set(paths.keys.filter { $0.hasPrefix(prefix) }.compactMap { $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init) }))
    }

    func text(_ path: String) -> String? { paths[path] ?? nil }
}

struct FakeKeychain: UninstallKeychain {
    /// By service, then group ("" for the login keychain).
    var items: [String: [String: [String]]]

    func accounts(service: String, accessGroup: String?) -> [String] { items[service]?[accessGroup ?? ""] ?? [] }
}
