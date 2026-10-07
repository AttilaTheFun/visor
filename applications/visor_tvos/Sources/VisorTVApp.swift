// The client on an Apple TV: the store of computers in the environment,
// the shared root view across the screen.

import SwiftUI
import VisorClient
import VisorServices
import VisorUI

@main
struct VisorTVApp: App {
    @StateObject private var store: VisorStore

    init() {
        // The host's services first: the store connects through them.
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(), settings: NativeVisorSettingsService(),
                             ssh: NativeVisorSSHService(), network: NativeVisorNetworkService())
        _store = StateObject(wrappedValue: VisorStore())
    }

    var body: some Scene {
        WindowGroup {
            VisorRootView()
                .environmentObject(store)
        }
    }
}
