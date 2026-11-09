import SwiftUI
import VisorClient
import VisorProtocol

/// A computer's page in Settings (VisorSettingsView): its provider's form.
@MainActor
struct ComputerSettingsView: View {
    var host: AgentServerConnection
    let forget: () -> Void

    var body: some View {
        AgentServerProviderUIs.ui(for: host.record.provider).settingsView(for: host, forget: forget)
            .navigationTitle(host.record.name.isEmpty ? "Computer" : host.record.name)
    }
}
