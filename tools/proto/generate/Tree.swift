import Foundation

/// Two folders of files compared.
enum Tree {
    /// How `made` and `kept` differ, file by file (paths under each): one
    /// only in either, or in both with other bytes. None when they match.
    static func differences(_ made: URL, _ kept: URL) throws -> [String] {
        let new = try files(in: made)
        let old = (try? files(in: kept)) ?? [:]
        var differences: [String] = []
        for path in Set(new.keys).union(old.keys).sorted() {
            switch (new[path], old[path]) {
            case (.some, .none): differences.append("\(path) is missing")
            case (.none, .some): differences.append("\(path) is not made from the protos")
            case (.some(let a), .some(let b)) where a != b: differences.append("\(path) differs")
            default: break
            }
        }
        return differences
    }

    /// Every file under `folder`, by its path under it, and its bytes.
    private static func files(in folder: URL) throws -> [String: Data] {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return [:] }
        guard let walk = manager.enumerator(atPath: folder.path) else { return [:] }
        var found: [String: Data] = [:]
        while let path = walk.nextObject() as? String {
            let url = folder.appendingPathComponent(path)
            guard manager.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { continue }
            found[path] = try Data(contentsOf: url)
        }
        return found
    }
}
