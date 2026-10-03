import SwiftUI
import VisorClient
import VisorProtocol

/// The settings in the detail column, for a server selected in the
/// sidebar: its provider's form.
@MainActor
struct ComputerSettingsView: View {
    @ObservedObject var host: AgentServerConnection
    let forget: () -> Void

    var body: some View {
        AgentServerProviderUIs.ui(for: host.record.provider).settingsView(for: host, forget: forget)
            .navigationTitle(host.record.name.isEmpty ? "Computer" : host.record.name)
    }
}
