import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// An archived session: the title, dimmed, with the full path of the
/// folder it ran in beneath it.
@MainActor
struct ArchivedRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(spacing: OutlineMetrics.gap) {
            Image(systemName: "archivebox")
                .foregroundColor(.secondary)
                .frame(width: OutlineMetrics.glyph, height: OutlineMetrics.glyph)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? session.agent.title : session.title)
                    .lineLimit(1)
                Text(session.cwd)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}
