// What Uninstall… reads of this Mac's filesystem (UninstallFiles), with
// FileManager: nothing here changes a file.

import Foundation
import VisorUninstall

struct MacUninstallFiles: UninstallFiles {
    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    func contents(ofFolder path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    func text(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}
