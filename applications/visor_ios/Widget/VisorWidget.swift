// The home screen's widget: the latest sessions on your computers — what
// each is called, its latest words, and whether it is working, waiting for
// you or working toward a goal. The app keeps what it shows up to date
// (WidgetFeed) and has it drawn again when it changes.

import Security
import SwiftUI
import WidgetKit

@main
struct VisorWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VisorSessions", provider: Provider()) { entry in
            VisorWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Sessions")
        .description("The latest from your agents: what each said last, and which are working, waiting or chasing a goal.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
