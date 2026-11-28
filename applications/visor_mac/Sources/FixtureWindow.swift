// A picture's window at the fixture's width (`-visor.fixture.width 320`:
// the content at its narrowest). A window that opens under about 500
// points wide keeps its sidebar whatever the split view is told, and the
// chat squeezed beside it spins its layout (a Nimbus VM, 27 Nov 2026); one
// opened wider with the sidebar hidden (NarrowWindow.opensNarrow) and then
// narrowed lays out as a person's dragged narrow does.

import AppKit
import VisorClient

enum FixtureWindow {
    /// The width the window opens at: the fixture's, but no narrower than
    /// the sidebar's room beside the content (620), where it opens with
    /// its sidebar hidden; nil for the default.
    @MainActor static var openingWidth: Double? {
        VisorFixture.windowWidth.map { max($0, 620) }
    }

    /// The window narrowed to the fixture's width, a moment after it is up.
    @MainActor static func narrow() async {
        guard let width = VisorFixture.windowWidth, width < 620 else { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
    }
}
