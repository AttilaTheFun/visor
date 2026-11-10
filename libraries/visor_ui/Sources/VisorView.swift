// Visor as one view, for an app that embeds it (Shireworks' Visor tab, as
// ReviewsView and IssuesView are theirs). The first one made installs the
// client's native services and opens its message cache, in places of the
// host's own: its settings under `visor.` in the host's defaults, its
// secrets (the computers it holds) under a keychain service of its own, its
// messages in a folder of its own. Every one shows the one store, with
// Settings as its own inspector (VisorRootView), whose being open a host may
// hold. A host shares Visor.app's computers by naming Visor's keychain
// service, with the keychain group that holds them in its entitlements.
// Pushes and the home screen's widget are the Visor app's: a host gets the
// notifications the device makes itself (for a computer that sends no
// pushes), once it allows them.

#if os(iOS) || os(macOS)
import Foundation
import MessageCache
import SwiftUI
import VisorClient
import VisorProtocol
import VisorServices
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public struct VisorView: View {
    private let settingsPresented: Binding<Bool>?
    @State private var store: VisorStore

    /// `keychainService`: where the computers are kept, for the first view
    /// made (later ones show the same store); by default the host's bundle
    /// id with `.visor`, apart from the host's own items.
    public init(settingsPresented: Binding<Bool>? = nil, keychainService: String? = nil) {
        self.settingsPresented = settingsPresented
        _store = State(initialValue: Self.store(keychainService: keychainService))
    }

    public var body: some View {
        VisorRootView(settingsPresented: settingsPresented)
            .environment(store)
    }

    private static var made: VisorStore?

    /// The one store, its services installed and its cache opened first.
    private static func store(keychainService: String?) -> VisorStore {
        if let made { return made }
        let host = Bundle.main.bundleIdentifier ?? "Visor"
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(host, isDirectory: true).appendingPathComponent("Visor", isDirectory: true)
        AgentServerConnection.cache = .open(named: "messages", in: folder)
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(),
                             settings: NativeVisorSettingsService(keychainService: keychainService ?? host + ".visor"),
                             notifications: NativeVisorNotificationService(), ssh: NativeVisorSSHService(),
                             network: NativeVisorNetworkService(), dictation: NativeVisorDictationService(),
                             deviceName: deviceName, appVersion: appVersion, platformName: platformName)
        let store = VisorStore()
        made = store
        return store
    }

    /// The host app's version ("1.2 (3)"), as Visor's own apps say theirs.
    private static var appVersion: String {
        guard let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "" }
        return VersionTitle.of(version: short, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    #if os(iOS)
    private static var deviceName: String { UIDevice.current.name }
    private static var platformName: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS" }
    #else
    private static var deviceName: String { Host.current().localizedName ?? "" }
    private static var platformName: String { "macOS" }
    #endif
}
#endif
