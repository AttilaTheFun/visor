import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// The sidebar's geometry, fixed: a row is inset 8pt, then a 16pt glyph
/// (the state dot or spinner, the archive box), 8pt, and the text. Rows
/// have 8pt above and below.
enum OutlineMetrics {
    // (A TV's glyphs are drawn at the TV's type, near twice a phone's.)
    static let glyph: CGFloat = Screen.tv ? 30 : 16
    static let gap: CGFloat = Screen.tv ? 14 : 8
}
