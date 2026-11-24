// Visor Disk Utility: one window with Visor's three volumes.

import ShireworksKit
import SwiftUI

/// Started by DiskUtilityMain when it's given no command.
struct DiskUtilityApp: App {
    @State private var model = VolumesModel()

    var body: some Scene {
        Window("Visor Disk Utility", id: "main") {
            VolumesView(model: model)
                .frame(minWidth: 600, minHeight: 760)
                .task { await model.refresh() }
                // Shireworks Kit: crashes and Help › Report a Bug… filed as
                // issues in the Info.plist's ShireworksRepository, and the
                // build written for Shireworks, whose offers of an update
                // its sheet answers (CI's builds to publish carry the keys).
                .shireworks()
        }
        .windowResizability(.contentSize)
        // Help › Report a Bug… (⌥⌘B).
        .commands { ShakeKitCommands() }
    }
}
