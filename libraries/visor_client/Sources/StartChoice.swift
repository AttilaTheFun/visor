/// One of a server's own starting points for a new session (a hosted
/// backend's template): its id goes where a folder's path would — the
/// session's `cwd`, which its project is grouped by — and its title is
/// what the sheet and the sidebar show.
public struct StartChoice: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// A line under the title, if the server says more of it.
    public var detail: String

    public init(id: String, title: String, detail: String = "") {
        self.id = id
        self.title = title
        self.detail = detail
    }
}
