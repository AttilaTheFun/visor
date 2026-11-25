// Visor on the Mac's welcome, while its window has no computers: this Mac's
// own server is a password away (OwnServer adds it once it has one), and
// other computers are added as anywhere else. The default welcome tells
// someone to download Visor Server, which this app is. This Mac's server is
// the server agent, or the one in the app (LocalServer), as it says over
// its API.

import SwiftUI
import VisorClient
import VisorProtocol
import VisorUI

@MainActor
struct MacOnboarding: VisorOnboarding {
    let local: LocalServer

    func isNeeded(_ store: VisorStore) -> Bool { store.servers.isEmpty }

    func view(_ store: VisorStore) -> AnyView { AnyView(MacOnboardingView(local: local)) }
}

@MainActor
private struct MacOnboardingView: View {
    let local: LocalServer
    @Environment(VisorStore.self) private var store

    static let readme = URL(string: "https://github.com/AttilaTheFun/visor#readme")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Visor runs Claude Code, Codex and other agents on this Mac and your other computers, and follows them from here.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    if local.mode == .handingBack {
                        Text("This Mac's server is starting.")
                    } else if let controls = local.controls {
                        if !controls.hasPassword {
                            Text("Choose a password in Settings: this Mac serves its agents once it has one, and shows here. The agents' command-line tools (Claude Code, Codex) are yours to install.")
                            Button("Open Settings…") { AppDelegate.openSettings() }
                        } else {
                            Text("This Mac's server is running. Add it here to start sessions on it.")
                            Button("Add This Mac") { OwnServer.add(controls, to: store) }
                        }
                    } else {
                        Text("This Mac's server isn't answering\(local.unreachable.map { ": \($0)" } ?? ".")")
                    }
                } header: {
                    Text("This Mac").textCase(nil)
                }
                Section {
                    Text("On another Mac, open Visor there and choose its password. On Linux or Windows, the visor-server command line does the same. Then copy its connection code from its menu, or scan the QR code in its Settings.")
                    Link("How to run visor-server", destination: Self.readme).font(.footnote)
                    // The same name as the list's row: the probes add a
                    // computer by it, whichever of the two is showing.
                    Button("Add Computer…") { store.addingServer = true }
                        .accessibilityIdentifier("add-computer")
                } header: {
                    Text("Other computers").textCase(nil)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)
            .navigationTitle("Welcome to Visor")
        }
    }
}
