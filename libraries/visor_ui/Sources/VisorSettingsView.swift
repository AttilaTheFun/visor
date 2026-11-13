// Visor's Settings, the app's own (Logan, 9 Nov 2026: every standalone app
// has one, from a Settings button in the navigation bar, and no tab bar):
// the computers, each one's settings a page of its own; the accounts, the
// fork's and each Runner's; this device's notifications and appearance
// (VisorPreferences); and About. The window's one trailing pane
// (VisorRootView, TrailingPane) shows it beside the detail in two columns
// and as a sheet in one; the Mac's server keeps its own settings in the
// menu bar app.

import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol
import VisorServices

@MainActor
struct VisorSettingsView: View {
    @Environment(VisorStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The app's own About section, if it gives one (EnvironmentValues+SettingsAbout).
    @Environment(\.settingsAbout) private var about
    /// This device's notifications and appearance.
    @Bindable private var preferences = VisorPreferences.shared
    /// The computer whose page is open, by its id (a sign-in link opens one).
    @Binding var computer: String?

    /// Whether Settings is in a sheet, its stack the sheet's (a phone's
    /// pane, the onboarding's): there a computer's page is pushed. Beside
    /// the detail (an inspector) it is not: a push from an inspector on the
    /// split view's detail column went to the detail column's stack, the
    /// computer's page over the session (10 Nov), so
    /// there the page takes Settings' place, with a way back.
    var inSheet = false

    var body: some View {
        if inSheet || sizeClass == .compact {
            list.navigationDestination(item: $computer) { id in page(id) }
        } else {
            NavigationStack {
                if let id = computer {
                    page(id)
                        .toolbar {
                            ToolbarItem(placement: .navigation) {
                                Button { computer = nil } label: { Label("Settings", systemImage: "chevron.backward") }
                                    .accessibilityIdentifier("settings-back")
                            }
                        }
                } else {
                    list
                }
            }
        }
    }

    /// A computer's page: its settings, and forgetting it.
    @ViewBuilder private func page(_ id: String) -> some View {
        if let host = store.server(for: id) {
            ComputerSettingsView(host: host, forget: {
                computer = nil
                store.remove(host)
            })
        }
    }

    /// Which kinds this device is told of, by every computer: a computer
    /// is told when one changes, and sends no push of a muted kind.
    private var notifications: some View {
        Section {
            ForEach(PushKind.allCases, id: \.self) { kind in
                Toggle(kind.title, isOn: Binding(get: { preferences.notifies(kind) }, set: { preferences.setNotifies(kind, $0) }))
                    .accessibilityIdentifier("settings-notify-" + kind.rawValue)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("What this device is told of, by every computer.")
        }
    }

    private var appearance: some View {
        Section {
            Picker("Appearance", selection: $preferences.appearance) {
                ForEach(VisorAppearance.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings-appearance")
        } header: {
            Text("Appearance")
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
            notifications
            appearance
            if let about {
                about
            } else {
                Section {
                    LabeledContent("Visor", value: VisorHost.appVersion.isEmpty ? "Development build" : VisorHost.appVersion)
                } header: {
                    Text("About")
                }
            }
        }
        .navigationTitle("Settings")
    }
}
