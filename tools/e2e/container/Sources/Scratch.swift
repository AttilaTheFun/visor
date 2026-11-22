// What //tools/e2e/container makes and deletes: a data folder of its own
// in /tmp (agent-proxy's data, the Containers layout, the relay's and the
// driver link's sockets: a socket's path must be short) and a folder on
// Sessions.
//
// With `--cache <folder>`, the Containers layout is that folder instead,
// kept between runs: the kernel, the image store (vminit's and the agent
// image's layers, the init filesystem) and the unpacked template stay, so a
// rerun skips the fetch and the template's unpacking (about 4 minutes).
// What is a run's own there (sessions/: the root filesystem's clone, its
// record, the boot and process logs; tools/: the programs staged) is
// deleted before the run, so each run boots a fresh clone, and after it
// (unless --keep). One run at a time per cache.

import Foundation
import VisorContainerCore

struct Scratch {
    let id = String(UUID().uuidString.prefix(8)).lowercased()
    /// /tmp/visor-e2e-container-<id>.
    let root: URL
    /// The server's data folder, as agent-proxy keeps it.
    let data: URL
    /// The Visor volume's Containers folder, as the engine lays it out:
    /// the run's own, or the cache.
    let layout: ContainerLayout
    /// Whether `layout` is a cache kept between runs.
    let cached: Bool
    let relaySocket: URL
    /// <Sessions>/.visor-e2e-container-<id>.
    let sessions: URL

    init(sessions volume: String, cache: URL? = nil) {
        root = URL(fileURLWithPath: "/tmp/visor-e2e-container-\(id)", isDirectory: true)
        data = root.appendingPathComponent("data", isDirectory: true)
        layout = ContainerLayout(root: cache ?? root.appendingPathComponent("Visor/Containers", isDirectory: true))
        cached = cache != nil
        relaySocket = root.appendingPathComponent("run/relay.sock")
        sessions = URL(fileURLWithPath: volume, isDirectory: true).appendingPathComponent(".visor-e2e-container-\(id)", isDirectory: true)
    }

    func make() throws {
        if cached { removeRunsOwn() }
        for folder in [root, data, layout.root, sessions] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// Everything it made, gone (the data folder kept if asked).
    func remove(keepingData keep: Bool) {
        try? FileManager.default.removeItem(at: sessions)
        if !keep {
            try? FileManager.default.removeItem(at: root)
            if cached { removeRunsOwn() }
        }
    }

    /// The cache's parts that are a run's own: its root filesystem and logs,
    /// and the programs it staged. The assets stay.
    private func removeRunsOwn() {
        try? FileManager.default.removeItem(at: layout.sessionsFolder)
        try? FileManager.default.removeItem(at: layout.toolsRoot)
    }
}
