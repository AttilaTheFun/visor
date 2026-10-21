// The desktop client: the same app as the Mac's, with visor's Foundation
// services installed directly — no bridge, this host is Swift all the way.

import SwiftUI
import VisorClient
import VisorServices
import VisorServicesNative
import VisorUI

@main
@MainActor
struct VisorDesktopApp: App {
    @State private var store: VisorStore

    init() {
        // Visor's services are main-actor isolated; an App's init runs on the
        // main thread, which Isomer does not say in the type system.
        MainActor.assumeIsolated {
            installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(), settings: NativeVisorSettingsService())
        }
        _store = State(initialValue: VisorStore())
    }

    var body: some Scene {
        WindowGroup {
            VisorRootView()
                .environment(store)
        }
    }
}
