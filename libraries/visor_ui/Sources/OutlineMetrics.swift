import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// The sidebar's geometry, fixed: a row's content is 24pt in from its
/// edges (SidebarRow), then a 16pt glyph (the archive box, the gear), 8pt,
/// and the text. Rows have 8pt above and below.
enum OutlineMetrics {
    static let glyph: CGFloat = 16
    static let gap: CGFloat = 8
}
