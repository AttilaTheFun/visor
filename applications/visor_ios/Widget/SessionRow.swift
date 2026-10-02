import Security
import SwiftUI
import WidgetKit

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
