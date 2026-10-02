import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// A session in the sidebar: its name, the full path of its folder, the first lines of
/// the latest message; and at the trailing edge what is happening — a
/// spinner while the agent works, a raised hand while it waits to be
/// allowed something. Whether the computer answers is its section's.
@MainActor
struct SessionCardRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(session.title.isEmpty ? session.agent.title : session.title)
                        .font(.headline)
                        .lineLimit(1)
                    // Working toward a goal, or looping: marked in the list.
                    if session.goal != nil {
                        Image(systemName: "flag.fill").font(.caption).foregroundColor(.accentColor)
                            .accessibilityLabel("Working toward a goal")
                    }
                    if session.loopWake != nil || session.loopCron != nil {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.caption).foregroundColor(.accentColor)
                            .accessibilityLabel("Looping")
                    }
                }
                Text(session.cwd)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.preview ?? "No messages yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if session.busy {
                // Screenshot tests want the same pixels every run.
                if VisorFixture.active {
                    Image(systemName: "ellipsis.circle.fill").foregroundColor(.secondary)
                        .accessibilityLabel("Working")
                } else {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Working")
                }
            } else if session.pendingApproval != nil {
                Image(systemName: "hand.raised.fill").foregroundColor(.yellow)
                    .accessibilityLabel("Waiting for approval")
            }
        }
        .accessibilityIdentifier("session-" + session.id)
    }
}
