// The Mac window at its narrowest: the content goes down to 320 points
// (Logan, 27 Nov 2026: the narrowest an iPad app gets in Stage Manager,
// as in Shireworks). AppKit's split view hides no column for the window's
// width: a window narrower than the sidebar and the content squeezed both
// and cut the chat off, and hiding the sidebar from a geometry change while
// squeezed spun the app's layout (Nimbus VM pictures, 27 Nov 2026). So the
// window is no narrower than its columns need: the content's 320 with the
// sidebar hidden, the sidebar's room beside it while it shows (showing it
// in a narrow window widens the window). The pane (Settings, a session's
// details) is a sheet where the detail column has no room for it beside the
// content. An iPad's and a phone's are their size class's.

import SwiftUI
import VisorClient

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

    /// Whether the window opens too narrow for the sidebar (a picture's
    /// fixture.width), so it opens hidden.
    @MainActor static var opensNarrow: Bool {
        applies && CGFloat(VisorFixture.windowWidth ?? .infinity) < besideSidebar
    }
}
