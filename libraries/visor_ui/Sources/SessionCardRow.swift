import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// A session in the sidebar: where its agent runs (a container, or the
/// computer's system), its name, a pin when it is pinned, its loop, and at
/// the end of that line a flag while it works toward a goal (a goal said
/// loosely can run away with it) and what is happening — a spinner while
/// the agent works, a clock while it waits on anything; then the full path
/// of its folder and the first lines of the latest message. What it waits
/// on, its subagents and its sub-sessions are its chat's (Logan, 26 Nov
/// 2026: in the list they were noise). Whether the computer answers is its
/// section's.
@MainActor
struct SessionCardRow: View {
    let session: SessionInfo
    /// The row is the selected one: its marks take its words' color, which
    /// the system's selection sets (white on the accent's fill).
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Where it runs, its name, its pin and loop; at the line's end
            // its goal and what is happening.
            HStack(spacing: 4) {
                // Only when it says (an empty mark would take the line's
                // spacing on Isomer).
                if SessionPlaceMark.shows(session) {
                    SessionPlaceMark(session: session)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("place-" + session.id)
                }
                Text(session.title.isEmpty ? session.agent.title : session.title)
                    .font(.headline)
                    .lineLimit(1)
                // Pinned to the top of its computer's list (Pin, in its menu).
                if session.pinnedAt != nil {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                        .accessibilityIdentifier("pinned-" + session.id)
                }
                if session.loopWake != nil || session.loopCron != nil {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(mark)
                        .accessibilityLabel("Looping")
                }
                Spacer(minLength: 8)
                if let goal = session.goal {
                    Image(systemName: "flag.fill").font(.caption).foregroundStyle(mark)
                        .accessibilityLabel("Goal: " + goal)
                        .accessibilityIdentifier("goal-" + session.id)
                }
                // Only when there is something (an empty mark would take
                // the line's spacing on Isomer).
                if Self.activity(of: session) != .none { activity }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("session-" + session.id)
    }

    /// What is happening at the line's end.
    enum Activity: Equatable {
        case working, waiting, none
    }

    /// From its turn's state (or, from a server before turn states, what
    /// its busy, approval and background say): working while the agent
    /// thinks, writes or runs a tool call of its own; waiting while it
    /// waits on anything else — an approval, a question, a sign-in, a
    /// subagent, a monitor, work left in the background. A monitor is one
    /// more thing waited on, not a mark of its own.
    static func activity(of session: SessionInfo) -> Activity {
        let turn = session.turn ?? TurnState.of(approval: session.pendingApproval, signIn: false, busy: session.busy, sending: false,
                                                responding: false, status: [], background: session.background)
        switch turn.phase {
        case .sending, .thinking, .responding: return .working
        case .waiting:
            let ownCalls = !turn.waits.isEmpty && turn.waits.allSatisfy { $0.kind == .tool && $0.work != .monitor }
            return ownCalls ? .working : .waiting
        case .idle: return .none
        }
    }

    /// What is happening: the agent works, or waits.
    @ViewBuilder private var activity: some View {
        switch Self.activity(of: session) {
        case .working:
            // Screenshot tests want the same pixels every run.
            if VisorFixture.active {
                Image(systemName: "ellipsis.circle.fill").foregroundStyle(.secondary)
                    .accessibilityLabel("Working")
                    .accessibilityIdentifier("activity-" + session.id)
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Working")
                    .accessibilityIdentifier("activity-" + session.id)
            }
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
                .accessibilityLabel("Waiting")
                .accessibilityIdentifier("activity-" + session.id)
        case .none:
            EmptyView()
        }
    }

    /// The goal's and the loop's marks: the accent, or the words' color on
    /// the selection.
    private var mark: AnyShapeStyle { selected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor) }
}
