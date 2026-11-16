// The headless client's @main: the store of computers in the environment
// and the shared root view, as the web's and Android's App.swift, with
// services of its own (settings in memory from the launch, no network)
// in place of a host's bridges.

import AgentUI
import Foundation
import SwiftUI
import VisorClient
import VisorServices
import VisorUI

@main
@MainActor
struct VisorHeadlessApp: App {
    @State private var store: VisorStore

    init() {
        // Visor's services are main-actor isolated; an App's init runs on
        // the main thread, which Isomer does not say in the type system.
        MainActor.assumeIsolated {
            let launch = ProcessInfo.processInfo
            installVisorServices(socket: OfflineSocketService(), http: OfflineHTTPService(),
                                 settings: LaunchSettingsService(environment: launch.environment, arguments: launch.arguments),
                                 deviceName: "Headless", platformName: "Headless")
        }
        _store = State(initialValue: VisorStore())
    }

    var body: some Scene {
        WindowGroup {
            VisorRootView()
                .environment(store)
                // As the web's and Android's: the ways to finish a draft
                // under the composer, not in a popover.
                .environment(\.suggestionsInPopover, false)
                .onOpenURL { url in store.open(url.absoluteString) }
        }
    }
}
