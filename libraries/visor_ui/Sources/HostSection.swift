import AgentUI
import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

/// A computer's section: observes the computer, so its rows and its
/// header follow the connection and the sessions as they change.
@MainActor
struct HostSection<Rows: View>: View {
    var host: AgentServerConnection
    @ViewBuilder let rows: (AgentServerConnection) -> Rows

    var body: some View {
        Section {
            rows(host)
        } header: {
            HStack(spacing: 6) {
                Circle().fill(host.badge.color).frame(width: 8, height: 8)
                Text(host.record.name.isEmpty ? host.record.address : host.record.name)
                    .lineLimit(1)
                Spacer()
            }
            .font(.subheadline)
            .noHeaderCase()
            // The dot is the state (why it is red is in the computer's
            // settings); VoiceOver reads it out.
            .accessibilityElement(children: .combine)
            .accessibilityValue(host.state.label)
            .accessibilityIdentifier("computer-" + host.record.name)
        }
    }
}
