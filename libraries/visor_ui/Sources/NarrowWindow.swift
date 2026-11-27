// The Mac window at its narrowest: the content goes down to 320 points
// (Logan, 27 Nov 2026: the narrowest an iPad app gets in Stage Manager,
// as in Shireworks). AppKit's split view doesn't hide a column for the
// window's width by itself: a window dragged narrower than the sidebar and
// the content squeezes both and cuts the chat off. So VisorRootView hides
// the sidebar below `besideSidebar` and makes the pane (Settings, a
// session's details) a sheet where the detail column is narrower than
// `besidePane`. An iPad's and a phone's are their size class's.

import SwiftUI

enum NarrowWindow {
    /// The content's least (the detail column's: VisorRootView).
    static let content: CGFloat = 320
    /// The window's width the sidebar needs beside the content: its ideal
    /// (300) and the content's least.
    static let besideSidebar: CGFloat = 300 + content
    /// The detail column's width the pane needs beside the content: the
    /// pane's ideal (AgentUI's adaptiveInspector, 300) and the content's
    /// least.
    static let besidePane: CGFloat = 300 + content

    /// Whether the window fits its columns by its width: the Mac's alone.
    static var applies: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}
