// Visor compiled against Isomer's frameworks: the client (Feature.swift and
// Visor's libraries, built in isomer's compiled-feature configuration) is
// linked into this app, and WasmView draws the tree it builds with Apple's
// SwiftUI, over isomer's native engine. The same source as red Visor, with
// Isomer's SwiftUI where Apple's would be.

import IsomerNativeRuntime
import IsomerWasmView
import SwiftUI

@main
struct VisorIsomerApp: App {
    init() {
        NativeFeatureRuntime.register()
    }

    var body: some Scene {
        WindowGroup {
            WasmView(provider: CompiledFeatureProvider())
        }
    }
}
