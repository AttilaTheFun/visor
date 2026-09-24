// The client's shell: the store of computers in the environment, the
// shared root view. One @main per platform, on shared sources.

import SwiftUI
import VisorClient
import VisorServices
import VisorUI

#if os(iOS)
@main
struct VisorApp: App {
    @StateObject private var store: VisorStore

    init() {
        // The host's services first: the store connects through them.
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(), settings: NativeVisorSettingsService())
        _store = StateObject(wrappedValue: VisorStore())
    }

    var body: some Scene {
        WindowGroup {
            VisorRootView()
                .environmentObject(store)
                // visor://connect?code=… — scanning a Mac's QR code with
                // the camera opens this, and adds that computer.
                .onOpenURL { url in store.open(url.absoluteString) }
        }
    }
}
#endif
