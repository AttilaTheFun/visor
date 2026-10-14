import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// A computer's section: observes the computer, so its rows and its
/// header follow the connection and the sessions as they change. The
/// header is a row on a phone (`inline`: SidebarSection).
@MainActor
struct HostSection<Rows: View>: View {
    var host: AgentServerConnection
    var inline = false
    @ViewBuilder let rows: (AgentServerConnection) -> Rows

    var body: some View {
        SidebarSection(inline: inline) {
            rows(host)
        } header: {
            HStack(spacing: 6) {
                Circle().fill(host.badge.color).frame(width: 8, height: 8)
                Text(host.record.name.isEmpty ? host.record.address : host.record.name)
                    .lineLimit(1)
                Spacer()
            }
            // The list's own header font, as its other sections have.
            .noHeaderCase()
            // The dot is the state (why it is red is in the computer's
            // settings); VoiceOver reads it out.
            .accessibilityElement(children: .combine)
            .accessibilityValue(host.state.label)
            .accessibilityIdentifier("computer-" + host.record.name)
        }
    }
}
