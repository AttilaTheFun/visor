// The home screen's widget: the latest sessions on your computers — what
// each is called, its latest words, and whether it is working, waiting for
// you or working toward a goal. The app keeps what it shows up to date
// (WidgetFeed) and has it drawn again when it changes.

import Security
import SwiftUI
import WidgetKit

struct SessionLine: Identifiable {
    let id: Int
    let computer: String
    let title: String
    let preview: String
    let state: String
    let updated: Date
}

struct Entry: TimelineEntry {
    let date: Date
    let sessions: [SessionLine]
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), sessions: [SessionLine(id: 0, computer: "Mac", title: "Offline sync",
                                                   preview: "Rows now sync in the background.", state: "working", updated: Date())])
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), sessions: Self.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app asks for a new one whenever the sessions change; this is
        // for the relative times, in between.
        completion(Timeline(entries: [Entry(date: Date(), sessions: Self.read())], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    /// The latest sessions, as the app last kept them.
    static func read() -> [SessionLine] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.LoganShire.VisorClient.widget",
                                    kSecAttrAccount as String: "sessions",
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["sessions"] as? [[String: Any]] else { return [] }
        return rows.enumerated().map { index, row in
            SessionLine(id: index, computer: row["computer"] as? String ?? "", title: row["title"] as? String ?? "",
                        preview: row["preview"] as? String ?? "", state: row["state"] as? String ?? "idle",
                        updated: Date(timeIntervalSince1970: (row["updated"] as? NSNumber)?.doubleValue ?? 0))
        }
    }
}

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

struct SessionRow: View {
    let line: SessionLine
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                StateMark(state: line.state).font(.caption)
                Text(line.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if !compact { Text(line.updated, style: .relative).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Text(line.preview).font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 3 : 1)
        }
    }
}

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
