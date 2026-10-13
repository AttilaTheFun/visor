/// What a move does for one project.
public struct MigrationStep: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// The folder is there already, and is used as it is.
        case present
        /// Cloned from its remote.
        case clone
        /// Copied across from where it was.
        case copy
        /// Made, empty: a folder that is not a repository.
        case create
    }

    /// Where the project was, and where it is (or goes) here.
    public var project: String
    public var path: String
    public var action: Action
    /// What the user is told of it.
    public var note: String
    /// Done unless the user says not: the session's own folder, and the
    /// projects it works in most.
    public var chosen: Bool

    public init(project: String, path: String, action: Action, note: String, chosen: Bool) {
        self.project = project
        self.path = path
        self.action = action
        self.note = note
        self.chosen = chosen
    }
}
