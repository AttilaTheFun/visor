import Security
import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let sessions: [SessionLine]
}
