// A sheet's least size on the Mac, where a sheet takes the size of what is
// in it: its own least width in a window of a usual width, as before, and
// the content's least (320, NarrowWindow) in a window too narrow for the
// sidebar beside it. An ideal width in place of the least width came out
// narrower than the least had made it (New Session at 470 points, not
// 520: a Nimbus VM, 27 Nov 2026), so the usual least stays.

import SwiftUI

struct MacSheetWidth: ViewModifier {
    /// Its least width in a window of a usual width.
    let width: CGFloat
    let height: CGFloat
    @Environment(\.narrowWindow) private var narrow

    func body(content: Content) -> some View {
        content.frame(minWidth: narrow ? NarrowWindow.content : width, minHeight: height)
    }
}
