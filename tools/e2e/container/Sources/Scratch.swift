// What //tools/e2e/container makes and deletes: a data folder of its own
// in /tmp (agent-proxy's data, the Containers layout, the relay's socket:
// a socket's path must be short) and a folder on Sessions.

import Foundation
import VisorContainerCore

struct Scratch {
    let id = String(UUID().uuidString.prefix(8)).lowercased()
    /// /tmp/visor-e2e-container-<id>.
    let root: URL
    /// The server's data folder, as agent-proxy keeps it.
    let data: URL
    /// The Containers volume's Visor folder, as the engine lays it out.
    let layout: ContainerLayout
    let relaySocket: URL
    /// <Sessions>/.visor-e2e-container-<id>.
    let sessions: URL

    init(sessions volume: String) {
        root = URL(fileURLWithPath: "/tmp/visor-e2e-container-\(id)", isDirectory: true)
        data = root.appendingPathComponent("data", isDirectory: true)
        layout = ContainerLayout(root: root.appendingPathComponent("Containers/Visor", isDirectory: true))
        relaySocket = root.appendingPathComponent("run/relay.sock")
        sessions = URL(fileURLWithPath: volume, isDirectory: true).appendingPathComponent(".visor-e2e-container-\(id)", isDirectory: true)
    }

    func make() throws {
        for folder in [root, data, layout.root, sessions] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// Everything it made, gone (the data folder kept if asked).
    func remove(keepingData keep: Bool) {
        try? FileManager.default.removeItem(at: sessions)
        if !keep { try? FileManager.default.removeItem(at: root) }
    }
}
