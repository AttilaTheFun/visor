// Visor Disk Utility: one window with Visor's two volumes.

import SwiftUI

/// Started by DiskUtilityMain when it's given no command.
struct DiskUtilityApp: App {
    @State private var model = VolumesModel()

    var body: some Scene {
        Window("Visor Disk Utility", id: "main") {
            VolumesView(model: model)
                .frame(minWidth: 600, minHeight: 760)
                .task { await model.refresh() }
        }
        .windowResizability(.contentSize)
    }
}
