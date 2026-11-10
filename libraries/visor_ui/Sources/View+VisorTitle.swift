// A screen's title in the toolbar, as navigationTitle, except inside a host
// on the Mac: its TabView's tab picker has the toolbar's centre, where an
// inline title went under it (Shireworks, 10 Nov 2026), so there is none.

import SwiftUI

extension View {
    func visorTitle(_ title: String) -> some View {
        modifier(VisorTitle(title: title))
    }
}

private struct VisorTitle: ViewModifier {
    let title: String
    @Environment(\.visorEmbedded) private var embedded

    func body(content: Content) -> some View {
        content.navigationTitle(embedded && Compat.tabPickerInToolbar ? "" : title)
    }
}
