import SwiftUI
import VisorClient
import VisorProtocol

/// The settings in the detail column, for a computer selected in the sidebar.
@MainActor
struct ComputerSettingsView: View {
    @ObservedObject var host: HostConnection
    let forget: () -> Void

    var body: some View {
        ComputerSettingsForm(host: host, forget: forget)
            .navigationTitle(host.config.name.isEmpty ? "Computer" : host.config.name)
    }
}
