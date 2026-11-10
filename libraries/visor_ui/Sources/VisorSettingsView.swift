// Visor's Settings, the app's own (Logan, 9 Nov 2026: every standalone app
// has one, from a Settings button in the navigation bar, and no tab bar):
// the computers, each one's settings a page of its own; the accounts, the
// fork's and each Runner's; and About. The window's one trailing pane
// (VisorRootView, TrailingPane) shows it beside the detail in two columns
// and as a sheet in one; the Mac's server keeps its own settings in the
// menu bar app.

import NavigationUI
import SwiftUI
import VisorClient
import VisorServices

@MainActor
struct VisorSettingsView: View {
    @Environment(VisorStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The computer whose page is open, by its id (a sign-in link opens one).
    @Binding var computer: String?

    var body: some View {
        // In one column the pane's sheet is a stack already; an inspector
        // isn't, so the computers' pages have one of their own there.
        if sizeClass == .compact {
            list
        } else {
            NavigationStack { list }
        }
    }

    private var list: some View {
        Form {
            Section {
                ForEach(store.servers) { host in
                    Button { computer = host.id } label: {
                        HStack {
                            Text(host.record.name.isEmpty ? host.record.address : host.record.name)
                            Spacer()
                            Text(host.state.label).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-computer-" + host.record.name)
                }
                Button { store.addingServer = true } label: {
                    Label(AgentServerProviderUIs.addTitle + "…", systemImage: "plus")
                }
                .accessibilityIdentifier("settings-add-computer")
            } header: {
                Text("Computers")
            }
            if let account = VisorAccounts.current { AccountSection(account: account) }
            ForEach(store.runners) { account in RunnerAccountSection(account: account) }
            Section {
                LabeledContent("Visor", value: VisorHost.appVersion.isEmpty ? "Development build" : VisorHost.appVersion)
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .navigationDestination(item: $computer) { id in
            if let host = store.server(for: id) {
                ComputerSettingsView(host: host, forget: {
                    computer = nil
                    store.remove(host)
                })
            }
        }
    }
}
