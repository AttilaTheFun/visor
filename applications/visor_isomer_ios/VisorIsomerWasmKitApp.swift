// Visor as wasm on WasmKit: the client — the same VisorUI screens the web
// and Android run, under isomer's SwiftUI — compiled to a wasm reactor and
// interpreted by WasmKit (isomer's WasmKitRuntime) in a native shell, which
// serves it its services (VisorIsomerServices, shared with the WAMR build)
// and draws its tree with real SwiftUI.
//
// Two reactors are bundled: one built for wasm32-unknown-wasip1-threads,
// whose Swift concurrency runs on a pool of guest threads, and the
// single-threaded one. The threaded one runs where WasmKit can make a shared
// memory (WasmKitRuntime.canRunThreads); otherwise the other does.

import Foundation
import IsomerWasmKitRuntime
import IsomerWasmRuntime
import IsomerWasmView
import SwiftUI

@main
struct VisorIsomerWasmKitApp: App {
    @StateObject private var model = WasmViewModel()

    /// The bundled reactor this device runs: the threaded one where WasmKit
    /// can make a shared memory, unless `ISO_WASMKIT_THREADS=0` is in the
    /// environment (benchmarks comparing the two).
    static let reactor = WasmKitRuntime.canRunThreads
        && ProcessInfo.processInfo.environment["ISO_WASMKIT_THREADS"] != "0" ? "visor_threads" : "visor"

    init() {
        // WasmKit, not WasmView's default WAMR. The guest's home is the
        // app's own container, as when the same app runs compiled.
        WasmRuntimeRegistry.register {
            let runtime = WasmKitRuntime()
            runtime.homeDirectory = NSHomeDirectory()
            runtime.bundleIdentifier = Bundle.main.bundleIdentifier
            return runtime
        }
        // Told to the servers the client reaches, so which engine and
        // which build this device runs shows in their clients list.
        visorHostPlatform = Self.reactor == "visor_threads"
            ? "iOS (Isomer, WasmKit, threads)" : "iOS (Isomer, WasmKit)"
        NSLog("[visor] WasmKit, reactor %@", Self.reactor)
    }

    var body: some Scene {
        WindowGroup {
            WasmView(
                model: model,
                provider: AppBundleProvider(resource: Self.reactor),
                ffiModulePrefix: visorFFIPrefix,
                dependencies: visorDependencies())
        }
    }
}
