import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

extension View {
    /// Dark bar chrome over the terminal, plain chrome everywhere else.
    /// An extension, not a ViewModifier: the portable SwiftUI has none.
    @ViewBuilder func terminalBarScheme(_ active: Bool) -> some View {
        #if os(iOS)
        toolbarColorScheme(active ? .dark : nil, for: .navigationBar)
        #else
        self
        #endif
    }
}
