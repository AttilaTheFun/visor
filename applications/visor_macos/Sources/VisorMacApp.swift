// The Mac client's @main, on the shared host sources.

import SwiftUI
import VisorClient
import VisorServices
import VisorUI

#if os(macOS)
@main
struct VisorMacApp: App {
    @StateObject private var store: VisorStore

    init() {
        // The host's services first: the store connects through them.
        installVisorServices(socket: NativeVisorSocketService(), http: NativeVisorHTTPService(), settings: NativeVisorSettingsService())
        _store = StateObject(wrappedValue: VisorStore())
        WindowShot.startIfAsked()
    }

    var body: some Scene {
        WindowGroup {
            VisorRootView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 480)
                // visor://connect?code=… — a connection code from a QR
                // code or a link adds that computer.
                .onOpenURL { url in store.open(url.absoluteString) }
        }
        // 240 + 240 for the two list columns and 720 for the thread, which
        // is where the transcript stops widening anyway.
        .defaultSize(width: 1200, height: 820)
        // The Mac keeps the computers in its menu bar; a phone and the web
        // reach the same sheet from a bar item.
        .commands {
            CommandMenu("Computers") {
                ForEach(store.hosts) { host in
                    Button("\(host.config.name.isEmpty ? host.config.host : host.config.name) — \(host.state.label)") {
                        host.disconnect()
                        host.connect()
                    }
                }
                if !store.hosts.isEmpty { Divider() }
                Button("Add Computer…") { store.addingComputer = true }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
            }
        }
    }
}
#endif

/// The app photographing its own window, for looking at it from
/// somewhere that cannot take a screenshot.
///
/// PARTLY WORKING. It captures the window and its text, but SwiftUI
/// draws much of itself in ways `CALayer.render(in:)` does not follow,
/// so lists and controls come back blank. Enough to tell which screen
/// is up, not enough to judge a layout by. The test VM can do the job
/// properly once its agent is granted Screen Recording, which needs
/// one click at the VM'"'"'s own window.
///
/// `screencapture` and everything like it needs Screen Recording, which
/// a headless test machine has no way to grant. Drawing your own view
/// into a bitmap needs nothing: it is your view. Set VISOR_SHOT to a
/// path and the window lands there every couple of seconds.
enum WindowShot {
    static func startIfAsked() {
        guard let path = ProcessInfo.processInfo.environment["VISOR_SHOT"], !path.isEmpty else { return }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { write(to: path) }
        }
    }

    @MainActor private static func write(to path: String) {
        // The biggest visible window: a sheet is small and on top, and
        // the window behind it is the one worth looking at.
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let view = window.contentView,
              let layer = view.layer,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        // The layer tree, not the view tree: SwiftUI draws into layers,
        // and `cacheDisplay` walks views, so it comes back nearly empty.
        // Core Animation's origin is the other corner, hence the flip.
        context.cgContext.translateBy(x: 0, y: view.bounds.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        layer.render(in: context.cgContext)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
