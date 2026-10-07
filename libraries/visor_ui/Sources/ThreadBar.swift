import AgentUI
import SwiftUI

/// The thread's bar: its title, and a control at the trailing end (the
/// session's details). The navigation bar elsewhere; on a TV, whose bar
/// has no background and whose list scrolls under it, a row of the
/// screen's own above the thread, in the thread's column (clear of the
/// sidebar the TV lays over the leading edge), and the bar hidden.
struct ThreadBar<Trailing: View>: ViewModifier {
    let title: String
    let trailing: Trailing

    func body(content: Content) -> some View {
        #if os(tvOS)
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title2.weight(.bold)).lineLimit(1)
                Spacer()
                trailing
            }
            .padding(.horizontal, TranscriptMetrics.edgeInset)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: TranscriptMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
            content
        }
        .toolbar(.hidden, for: .navigationBar)
        #else
        content
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { trailing }
            }
        #endif
    }
}
