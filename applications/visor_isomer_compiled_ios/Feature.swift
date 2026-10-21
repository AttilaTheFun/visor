// The client compiled against Isomer's frameworks (isomer's apple/compiled):
// the same VisorUI screens red Visor runs, where `import SwiftUI` is Isomer's,
// with the services Visor's own iOS app installs (Visor's native ones, over
// Apple's Foundation). The host app (App.swift) draws the tree it builds.

import SwiftUI
import UIKit
import VisorClient
import VisorServices
import VisorUI

@main
struct VisorCompiledFeature: App {
    @State private var store: VisorStore

    /// This app's version and build ("0.32 (1)").
    static var bundleVersion: String {
        guard let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "" }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    init() {
        // Red Visor's services but notifications and the widget (this app
        // has neither push entitlement nor widget).
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(), settings: NativeVisorSettingsService(),
                             ssh: NativeVisorSSHService(), network: NativeVisorNetworkService(),
                             dictation: NativeVisorDictationService(), deviceName: UIDevice.current.name,
                             appVersion: Self.bundleVersion, platformName: UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS")
        _store = State(initialValue: VisorStore())
    }

    var body: some Scene {
        WindowGroup {
            VisorRootView()
                .environment(store)
                // A `visor://connect?code=…` link adds its computer.
                .onOpenURL { url in store.open(url.absoluteString) }
        }
    }
}
