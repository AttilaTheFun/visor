/// What the window's one trailing pane shows: Settings, or a session's
/// details (SessionInspector). One pane, never two: on a Mac a closed
/// inspector of the chat's own beside Settings sent AppKit's
/// update-constraints pass round until the app spun or threw (the Mac
/// proof's settings screens, 10 Nov 2026).
enum TrailingPane: Hashable {
    case settings
    case session(SessionSelection)
}
