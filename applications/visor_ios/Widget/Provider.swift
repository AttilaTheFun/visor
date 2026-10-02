import Security
import SwiftUI
import WidgetKit

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
