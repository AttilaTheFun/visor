// The client's shell: the store of computers in the environment, the
// shared root view. One @main per platform, on shared sources.

import SwiftUI
import VisorClient
import VisorServices
import VisorUI

#if os(iOS)
@main
struct VisorApp: App {
    @State private var store: VisorStore
    /// Where the system hands over the push token and the notification
    /// the user opened (PushDelegate).
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate

    init() {
        // The host's services first: the store connects through them.
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(), settings: NativeVisorSettingsService(),
                             notifications: NativeVisorNotificationService(), widget: WidgetFeed(), ssh: NativeVisorSSHService(), network: NativeVisorNetworkService(),
                             dictation: NativeVisorDictationService())
        // Asked once, at first launch: turns finished, goals done, agents
        // waiting for approval.
        // (Not for screenshot tests, which a prompt would cover.)
        if !VisorFixture.active {
            VisorHost.notifications?.requestPermission()
            // A token for pushes, which each computer is given.
            VisorHost.notifications?.registerForRemoteNotifications()
        }
        _store = State(initialValue: VisorStore())
    }

    var body: some Scene {
        WindowGroup {
            VisorRootView()
                .environment(store)
                // visor://connect?code=… — scanning a Mac's QR code with
                // the camera opens this, and adds that computer.
                .onOpenURL { url in store.open(url.absoluteString) }
        }
    }
}
#endif
