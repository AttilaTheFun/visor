// The web client's @main: the store of computers (through the page's
// settings service) in the environment, the shared root view. The page
// injects the socket and settings services before the app boots.

import AgentUI
import SwiftUI
import VisorClient
import VisorServicesFFI
import VisorUI

@main
@MainActor
struct VisorWebApp: App {
    @State private var store: VisorStore

    init() {
        installBridgedVisorServices()
        _store = State(initialValue: VisorStore())
    }

    var body: some Scene {
        WindowGroup {
            VisorRootView()
                .environment(store)
                // On an iPhone or iPad the ways to finish a draft are a
                // popover, as the native app's are: AgentUI chooses by this
                // (on by default only where it is built for iOS, which this
                // app, built for WASI, is not), so its host says.
                .environment(\.suggestionsInPopover, hostPlatform().hasPrefix("iOS"))
                // A `visor://connect?code=…` link (a scanned QR code, a
                // pasted code) adds its computer, as the iOS app does.
                .onOpenURL { url in store.open(url.absoluteString) }
        }
    }
}
