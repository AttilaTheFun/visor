import Security
import SwiftUI
import WidgetKit

struct VisorWidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    private var count: Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 3
        default: 6
        }
    }

    var body: some View {
        if entry.sessions.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "eye").font(.title2)
                Text("Open Visor to see your sessions here.").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 0 : 8) {
                ForEach(entry.sessions.prefix(count)) { line in SessionRow(line: line, compact: family == .systemSmall) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
