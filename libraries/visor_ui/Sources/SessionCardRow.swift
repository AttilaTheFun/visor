import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// A session in the sidebar: where its agent runs (a container, or the
/// computer's system), its name, its goal and loop, and at the end of that
/// line what is happening — a spinner while the agent works, a raised hand
/// while it waits to be allowed something; then the full path of its
/// folder, the first lines of the latest message, and the machines it
/// leases. Whether the computer answers is its section's.
@MainActor
struct SessionCardRow: View {
    let session: SessionInfo
    /// The row is the selected one: its marks take its words' color, which
    /// the system's selection sets (white on the accent's fill).
    var selected = false
    /// Opens what the computer is using (its containers, its machines):
    /// what the row's container mark and its machines do when tapped.
    var showResources: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Where it runs, its name, its goal and loop; at the line's end
            // what is happening.
            HStack(spacing: 4) {
                // Only when it says (an empty mark would take the line's
                // spacing on Isomer).
                if SessionPlaceMark.shows(session) {
                    resourcesButton {
                        SessionPlaceMark(session: session)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("place-" + session.id)
                }
                Text(session.title.isEmpty ? session.agent.title : session.title)
                    .font(.headline)
                    .lineLimit(1)
                // Working toward a goal, or looping: marked in the list.
                if session.goal != nil {
                    Image(systemName: "flag.fill").font(.caption).foregroundStyle(mark)
                        .accessibilityLabel("Working toward a goal")
                }
                if session.loopWake != nil || session.loopCron != nil {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(mark)
                        .accessibilityLabel("Looping")
                }
                Spacer(minLength: 8)
                activity
            }
            Text(session.cwd)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(session.preview ?? "No messages yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            // Between turns, what the agent is waiting on in the
            // background: a monitor, a command, an agent of its own.
            if !session.busy, let waiting = Self.waitingLine(session.background) {
                Text(waiting)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("waiting-" + session.id)
            }
            if !session.leases.isEmpty {
                resourcesButton { LeaseMarks(leases: session.leases) }
                    .padding(.top, 2)
                    .accessibilityIdentifier("leases-" + session.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("session-" + session.id)
    }

    /// A mark that opens the computer's resources when tapped, without
    /// selecting the row; only the mark where there is nowhere to open.
    @ViewBuilder private func resourcesButton(@ViewBuilder _ label: () -> some View) -> some View {
        if let showResources {
            // Plain: the marks keep their own grey (a tinted button's
            // secondary is the accent's), and the tap is the mark's alone.
            Button(action: showResources, label: label)
                .buttonStyle(.plain)
                .accessibilityHint("Shows what the computer is using")
        } else {
            label()
        }
    }

    /// What is happening: the agent works, waits to be allowed something,
    /// or waits on work in the background.
    @ViewBuilder private var activity: some View {
        if session.busy {
            // Screenshot tests want the same pixels every run.
            if VisorFixture.active {
                Image(systemName: "ellipsis.circle.fill").foregroundStyle(.secondary)
                    .accessibilityLabel("Working")
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Working")
            }
        } else if session.pendingApproval != nil {
            Image(systemName: "hand.raised.fill").foregroundColor(.yellow)
                .accessibilityLabel("Waiting for approval")
        } else if !session.background.isEmpty {
            Image(systemName: "clock").foregroundStyle(.secondary)
                .accessibilityLabel("Waiting on background work")
        }
    }

    /// The goal's and the loop's marks: the accent, or the words' color on
    /// the selection.
    private var mark: AnyShapeStyle { selected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor) }

    /// "Waiting on CI checks on PR #92" — the first, and how many more.
    static func waitingLine(_ background: [StatusItem]) -> String? {
        guard let first = background.first else { return nil }
        let more = background.count - 1
        return "Waiting on " + first.label + (more > 0 ? " and \(more) more" : "")
    }
}
