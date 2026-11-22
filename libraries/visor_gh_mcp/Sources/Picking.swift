import Foundation

/// A summary's fields from GitHub's answer: each path read, null when
/// missing.
func pick(_ json: JSON, _ fields: [(String, [String])]) -> JSON {
    var object: [String: JSON] = [:]
    for (name, path) in fields {
        var value: JSON? = json
        for key in path { value = value?[key] }
        object[name] = value ?? .null
    }
    return .object(object)
}

func merge(_ a: JSON, _ b: [String: JSON]) -> JSON {
    var object = a.objectValue ?? [:]
    for (key, value) in b { object[key] = value }
    return .object(object)
}
