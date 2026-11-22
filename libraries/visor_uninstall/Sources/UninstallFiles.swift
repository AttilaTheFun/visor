// What Uninstall… reads of the filesystem to make its plan: the Mac's
// (FileManager, in Visor Disk Utility), or a test's.

public protocol UninstallFiles: Sendable {
    /// Whether anything is at the path (a link too, whatever it points at).
    func exists(_ path: String) -> Bool
    /// A folder's names, none for no folder.
    func contents(ofFolder path: String) -> [String]
    /// A file's text; nil when there's none.
    func text(_ path: String) -> String?
}
