// A volume's tree walked, the system's folders at its root and the
// conversion's marker left out, links never followed.

import Foundation

public enum VolumeTree {
    /// Calls `visit` with each path under `root` (relative, `a/b`) and
    /// what `inspector` says of it; a folder is gone into when `visit`
    /// says so and it's readable. Throws when a folder that's gone into
    /// can't be listed.
    public static func walk(_ root: String, inspector: some FileInspecting,
                            visit: (String, FileInspection) throws -> Bool) throws {
        try walk(root: root, relative: "", inspector: inspector, visit: visit)
    }

    private static func walk(root: String, relative: String, inspector: some FileInspecting,
                             visit: (String, FileInspection) throws -> Bool) throws {
        let folder = relative.isEmpty ? root : (root as NSString).appendingPathComponent(relative)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder)
        } catch {
            throw DiskVolumesError.failed("\(folder) couldn't be read: \(error.localizedDescription)")
        }
        for name in names {
            if relative.isEmpty, VolumeManifest.leftOutAtRoot.contains(name) { continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            let file = try inspector.inspect((root as NSString).appendingPathComponent(path))
            if try visit(path, file), file.kind == .directory, file.readable {
                try walk(root: root, relative: path, inspector: inspector, visit: visit)
            }
        }
    }
}
