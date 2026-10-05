// One of an account's allowances: how much is used, as a bar, and when
// it starts over or what is left.

import SwiftUI
import VisorProtocol

struct UsageLimitRow: View {
    let limit: UsageLimit
    let now: Double

    /// A window whose reset has passed since it was said has started over:
    /// what it said is used is no longer so.
    private var lapsed: Bool { limit.resets.map { $0 <= now } ?? false }

    private var detail: String {
        var parts: [String] = []
        if let left = limit.left {
            let amount = limit.unit == .dollars ? UsageWords.dollars(left) : UsageWords.grouped(Int64(whole: left))
            let total = limit.total.map { " of " + (limit.unit == .dollars ? UsageWords.dollars($0) : UsageWords.grouped(Int64(whole: $0))) } ?? ""
            parts.append(amount + total + " left")
        }
        if let resets = limit.resets {
            parts.append(lapsed ? "Has started over" : "Resets in " + UsageWords.duration(resets - now))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if let used = limit.used {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(limit.name)
                    Spacer()
                    Text(lapsed ? "—" : UsageWords.percent(used) + " used").foregroundColor(.secondary)
                }
                ProgressView(value: lapsed ? 0 : min(1, max(0, used)))
                    .tint(used >= 0.9 ? .red : used >= 0.75 ? .orange : .accentColor)
                if !detail.isEmpty {
                    Text(detail).font(.footnote).foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)
        } else {
            LabeledContent(limit.name, value: detail)
        }
    }
}
