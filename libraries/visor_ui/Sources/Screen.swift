/// What the views are drawn on, where a layout differs by it: a
/// television, read from across a room through a fixed-width sidebar.
enum Screen {
    /// A television.
    static let tv: Bool = {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }()
}
