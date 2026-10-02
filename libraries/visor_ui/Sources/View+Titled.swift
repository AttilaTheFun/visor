import SwiftUI
import VisorClient
import VisorProtocol

extension View {
    /// A navigation title, or none: a pane inside a window must not name
    /// the window.
    @ViewBuilder func titled(_ title: String, when show: Bool) -> some View {
        if show { navigationTitle(title) } else { self }
    }
}
