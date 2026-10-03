/// A folder on a server: its resolved path, its subfolders, and whether
/// it is there at all.
public struct FolderListing: Equatable, Sendable {
    public var path: String
    public var folders: [String]
    public var exists: Bool
    public init(path: String, folders: [String], exists: Bool = true) {
        self.path = path
        self.folders = folders
        self.exists = exists
    }
}
