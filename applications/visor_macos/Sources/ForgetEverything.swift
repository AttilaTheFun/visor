// Settings' Forget Everything, Visor Client's: what the app keeps, gone,
// and then it quits. Its computers (each disconnected, its password
// cleared), every keychain item under its service, its defaults, and the
// folders it keeps in its container's Library (the message cache in
// Application Support, URLSession's caches, the windows' saved state).
// What it can't remove from inside its sandbox, the uninstall does
// (docs/visor-client.md): the container itself, and macOS's privacy
// answers (`tccutil reset All com.LoganShire.VisorClient.macOS`).

#if os(macOS)
import AppKit
import UserNotifications
import VisorClient
import VisorServices

@MainActor
enum ForgetEverything {
    static func run(store: VisorStore, settings: NativeVisorSettingsService) {
        for server in store.servers { store.remove(server) }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.LoganShire.VisorClient.macOS"
        settings.forgetEverything(domain: bundleID)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        NSApplication.shared.unregisterForRemoteNotifications()
        // The windows aren't saved as the app quits: it starts afresh.
        for window in NSApplication.shared.windows { window.isRestorable = false }
        for folder in folders(bundleID: bundleID) { try? FileManager.default.removeItem(at: folder) }
        NSApplication.shared.terminate(nil)
    }

    /// The app's own folders in its Library: in the sandbox, its
    /// container's (~/Library/Containers/<bundle id>/Data/Library).
    static func folders(bundleID: String) -> [URL] {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return ["Application Support/" + bundleID, "Caches/" + bundleID, "HTTPStorages/" + bundleID,
                "Saved Application State/" + bundleID + ".savedState"]
            .map { library.appendingPathComponent($0, isDirectory: true) }
    }
}
#endif
