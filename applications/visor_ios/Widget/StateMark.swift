import Security
import SwiftUI
import WidgetKit

/// What a session is doing, as a glyph.
struct StateMark: View {
    let state: String
    var body: some View {
        switch state {
        case "working": Image(systemName: "ellipsis.circle.fill").foregroundStyle(.blue)
        case "waiting": Image(systemName: "hand.raised.fill").foregroundStyle(.yellow)
        case "goal": Image(systemName: "flag.fill").foregroundStyle(.blue)
        default: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        }
    }
}
