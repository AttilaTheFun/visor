import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// A session in the sidebar: its name, the full path of its folder, the first lines of
/// the latest message (a terminal, marked, has none); and at the trailing edge what is happening — a
/// spinner while the agent works, a raised hand while it waits to be
/// allowed something. Whether the computer answers is its section's.
@MainActor
struct SessionCardRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if session.agent.isShell {
                        Image(systemName: "terminal").font(.caption).foregroundColor(.secondary)
                            .accessibilityLabel("Terminal")
                    }
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
                // (A TV's sidebar, at the TV's type, has room for the
                // folder's name and one line of the message.)
                Text(Screen.tv ? Self.folderName(session.cwd) : session.cwd)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // A terminal has no messages: its folder says where it is.
                if !session.agent.isShell {
                    Text(session.preview ?? "No messages yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(Screen.tv ? 1 : 2)
                }
                // Between turns, what the agent is waiting on in the
                // background: a monitor, a command, an agent of its own.
                if !session.busy, let waiting = Self.waitingLine(session.background) {
                    Text(waiting)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("waiting-" + session.id)
                }
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
            } else if !session.background.isEmpty {
                Image(systemName: "clock").foregroundColor(.secondary)
                    .accessibilityLabel("Waiting on background work")
            }
        }
        .accessibilityIdentifier("session-" + session.id)
    }

    /// The folder's own name: the last part of its path.
    static func folderName(_ cwd: String) -> String {
        cwd.split(separator: "/").last.map(String.init) ?? cwd
    }

    /// "Waiting on CI checks on PR #92" — the first, and how many more.
    static func waitingLine(_ background: [StatusItem]) -> String? {
        guard let first = background.first else { return nil }
        let more = background.count - 1
        return "Waiting on " + first.label + (more > 0 ? " and \(more) more" : "")
    }
}
