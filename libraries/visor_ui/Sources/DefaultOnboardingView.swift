import SwiftUI
import VisorClient

/// The default onboarding's page: three steps — Visor Server on a computer,
/// a VPN to reach it away from home, the computer added here — and the add
/// sheet a tap away.
@MainActor
struct DefaultOnboardingView: View {
    @Environment(VisorStore.self) private var store

    static let releases = URL(string: "https://github.com/AttilaTheFun/visor/releases/latest")!
    static let readme = URL(string: "https://github.com/AttilaTheFun/visor#readme")!
    static let tailscale = URL(string: "https://tailscale.com/download")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Visor runs Claude Code, Codex and other agents on your own computers, and follows them from here. Three steps to set one up.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("On a Mac, download Visor Server, drag it to Applications and open it: it lives in the menu bar. Choose a password in its Settings. The agents' command-line tools (Claude Code, Codex) are yours to install there.")
                    Link("Download Visor Server", destination: Self.releases)
                    Text("On Linux or Windows, the visor-server command line does the same.").font(.footnote).foregroundStyle(.secondary)
                    Link("How to run visor-server", destination: Self.readme).font(.footnote)
                } header: {
                    Text("1. Run Visor Server on your computer").noHeaderCase()
                }
                Section {
                    Text("At home this device reaches the computer over your Wi-Fi. To reach it from anywhere, put both on a VPN of your own, such as Tailscale: install it on the computer and on this device, and sign in to the same account on each.")
                    Link("Get Tailscale", destination: Self.tailscale)
                } header: {
                    Text("2. Reach it from anywhere").noHeaderCase()
                }
                Section {
                    Text("In Visor Server's menu, Copy Connection Code and paste it here, or open its Settings and scan the QR code with this device's camera.")
                    // The same name as the list's row: the probes add a
                    // computer by it, whichever of the two is showing.
                    Button("Add Computer…") { store.addingServer = true }
                        .accessibilityIdentifier("add-computer")
                } header: {
                    Text("3. Add it here").noHeaderCase()
                }
            }
            .insetGroupedForm()
            .navigationTitle("Welcome to Visor")
        }
    }
}
