// Where Visor keeps what is its own, with the Visor volume and without it,
// and what was in the home folder moved onto it once. Scratch folders
// stand in for the home folder and the volume: nothing here touches either.

import DiskVolumes
import Foundation
import Synchronization
import Testing

@Suite struct FolderTests {
    /// A scratch home and a scratch "volume" (any folder: the mount point
    /// check is the test's).
    private struct Scratch {
        let root: URL
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }
        var volume: URL { root.appendingPathComponent("Visor", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-folders-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Visor"), withIntermediateDirectories: true)
        }

        var folders: VisorFolders { VisorFolders(volume: volume.path, home: home.path) }
        var without: VisorFolders { VisorFolders(volume: nil, home: home.path) }

        func write(_ text: String, _ path: String, in base: URL) throws {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func read(_ path: String, in base: URL) -> String? {
            (try? Data(contentsOf: base.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
        }

        func exists(_ path: String, in base: URL) -> Bool { FileManager.default.fileExists(atPath: base.appendingPathComponent(path).path) }
    }

    @Test func withoutTheVolumeEverythingIsWhereItWas() {
        let folders = VisorFolders.locate(home: "/Users/someone") { _ in false }
        #expect(!folders.onVolume)
        #expect(folders.data.path == "/Users/someone/Library/Application Support/Visor")
        #expect(folders.caches("Server", bundleID: "com.LoganShire.Visor").path
            == "/Users/someone/Library/Application Support/com.LoganShire.Visor/Server")
        #expect(folders.logs.path == "/Users/someone/Library/Logs")
        #expect(folders.log("Visor-server.log") == "/Users/someone/Library/Logs/Visor-server.log")
        #expect(folders.temporary == nil)
        #expect(folders.socket == nil)
        #expect(folders.containers == nil)
        #expect(VisorFolderMove.dataFolder(folders) == folders.legacyData)
    }

    @Test func withTheVolumeEverythingIsOnIt() {
        let folders = VisorFolders.locate(home: "/Users/someone") { $0 == "/Volumes/Visor" }
        #expect(folders.volume == "/Volumes/Visor")
        #expect(folders.data.path == "/Volumes/Visor/Data")
        #expect(folders.caches("Client", bundleID: "com.LoganShire.Visor").path == "/Volumes/Visor/Caches/Client")
        #expect(folders.logs.path == "/Volumes/Visor/Logs")
        #expect(folders.temporary?.path == "/Volumes/Visor/tmp")
        #expect(folders.socket == "/Volumes/Visor/run/server.sock")
        #expect(folders.containers?.path == "/Volumes/Visor/Containers")
        #expect(folders.legacySocketFolder.path == "/Users/someone/.visor")
        // Nothing in the home folder to move (none there): the volume's.
        #expect(VisorFolderMove.dataFolder(folders).path == "/Volumes/Visor/Data")
    }

    @Test func theDataFolderMovesOnceButForTheSessionsFolders() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        let legacy = scratch.folders.legacyData
        try scratch.write(#"{"sessions":[]}"#, "sessions.json", in: legacy)
        try scratch.write("{}", "settings.json", in: legacy)
        try scratch.write("job", "super-compact/s/j/job.json", in: legacy)
        try scratch.write("log", "hosts/hosts.log", in: legacy)
        try scratch.write("x", "Sessions/Claude/abc/notes.md", in: legacy)
        // Until it moves, the server keeps to the home folder's.
        #expect(VisorFolderMove.dataFolder(scratch.folders) == legacy)
        // Without the volume, nothing moves.
        #expect(VisorFolderMove(folders: scratch.without, answers: { _ in false }).moveData() == .nothing)

        let move = VisorFolderMove(folders: scratch.folders, answers: { _ in false })
        #expect(move.moveData() == .moved(["hosts", "sessions.json", "settings.json", "super-compact"]))
        let data = scratch.folders.data
        #expect(scratch.read("sessions.json", in: data) == #"{"sessions":[]}"#)
        #expect(scratch.read("super-compact/s/j/job.json", in: data) == "job")
        #expect(scratch.exists("hosts/hosts.log", in: data))
        // The sessions moved in stay at the paths they're known by.
        #expect(scratch.read("Sessions/Claude/abc/notes.md", in: legacy) == "x")
        #expect(!scratch.exists("Sessions", in: data))
        #expect(VisorFolderMove.pending(in: legacy).isEmpty)
        #expect(VisorFolderMove.dataFolder(scratch.folders) == data)
        // Once: again, nothing.
        #expect(move.moveData() == .nothing)
    }

    @Test func anEmptiedDataFolderIsRemoved() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        let legacy = scratch.folders.legacyData
        try scratch.write("{}", "settings.json", in: legacy)
        try scratch.write("", ".DS_Store", in: legacy)
        #expect(VisorFolderMove(folders: scratch.folders, answers: { _ in false }).moveData() == .moved(["settings.json"]))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func itWaitsWhileAnAgentsHostAnswers() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        let legacy = scratch.folders.legacyData
        try scratch.write("{}", "sessions.json", in: legacy)
        try scratch.write("", "hosts/abcdef12-1a2b.sock", in: legacy)
        let asked = Mutex<[String]>([])
        let waiting = VisorFolderMove(folders: scratch.folders, answers: { path in
            asked.withLock { $0.append(path) }
            return true
        }).moveData()
        guard case .waiting(let why) = waiting else { Issue.record("\(waiting)"); return }
        #expect(why.contains("still answers"))
        #expect(asked.withLock { $0 } == [legacy.appendingPathComponent("hosts/abcdef12-1a2b.sock").path])
        #expect(scratch.exists("sessions.json", in: legacy))
        #expect(VisorFolderMove.dataFolder(scratch.folders) == legacy)
        // Once no host answers (the agents ended), it moves.
        #expect(VisorFolderMove(folders: scratch.folders, answers: { _ in false }).moveData() == .moved(["hosts", "sessions.json"]))
    }

    /// No host answers: the hosts' socket files are dead, and are removed
    /// rather than moved (a socket can't be copied to another volume, which
    /// left `hosts/` behind on the Mini), the rest of `hosts/` moving.
    @Test func deadHostsSocketsAreRemovedNotMoved() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        let legacy = scratch.folders.legacyData
        try scratch.write("{}", "settings.json", in: legacy)
        try scratch.write("", "hosts/abcdef12-1a2b.sock", in: legacy)
        try scratch.write("t", "hosts/abcdef12-1a2b.token", in: legacy)
        #expect(VisorFolderMove(folders: scratch.folders, answers: { _ in false }).moveData() == .moved(["hosts", "settings.json"]))
        #expect(!scratch.exists("hosts/abcdef12-1a2b.sock", in: scratch.folders.data))
        #expect(scratch.read("hosts/abcdef12-1a2b.token", in: scratch.folders.data) == "t")
        #expect(VisorFolderMove.dataFolder(scratch.folders) == scratch.folders.data)
    }

    /// The settings on the volume and something left in the home folder (a
    /// move that couldn't take it): the volume's data folder is used, never
    /// the home folder the settings have left, where a server would make
    /// new settings, a new id and no sessions.
    @Test func withTheSettingsMovedTheVolumesDataFolderIsUsedWhateverIsLeft() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        try scratch.write("{\"id\":\"kept\"}", "settings.json", in: scratch.folders.data)
        try scratch.write("x", "hosts/left.token", in: scratch.folders.legacyData)
        #expect(VisorFolderMove.pending(in: scratch.folders.legacyData) == ["hosts"])
        #expect(VisorFolderMove.dataFolder(scratch.folders) == scratch.folders.data)
        // Without settings on the volume, the home folder's is used, as before.
        try FileManager.default.removeItem(at: scratch.folders.data.appendingPathComponent("settings.json"))
        #expect(VisorFolderMove.dataFolder(scratch.folders) == scratch.folders.legacyData)
    }

    @Test func whatTheVolumeHasAlreadyIsKeptAndTheHomeFoldersPutAside() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        let legacy = scratch.folders.legacyData
        let data = scratch.folders.data
        try scratch.write("old", "volumes.json", in: legacy)
        try scratch.write("home", "push.json", in: legacy)
        try scratch.write("new", "volumes.json", in: data)
        try scratch.write("volume", "push.json", in: data)
        #expect(VisorFolderMove(folders: scratch.folders, answers: { _ in false }).moveData() == .moved(["push.json"]))
        // volumes.json is Visor Disk Utility's, written to the volume: the old one goes.
        #expect(scratch.read("volumes.json", in: data) == "new")
        #expect(scratch.read("push.json", in: data) == "volume")
        #expect(scratch.read("moved-aside/push.json", in: data) == "home")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func aCacheMovesWholeOrIsDropped() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        let bundle = "com.LoganShire.Visor"
        let folders = scratch.folders
        let move = VisorFolderMove(folders: folders, answers: { _ in false })
        try scratch.write("server", "messages.sqlite", in: folders.legacyCaches("Server", bundleID: bundle))
        try scratch.write("wal", "messages.sqlite-wal", in: folders.legacyCaches("Server", bundleID: bundle))
        try scratch.write("client", "messages.sqlite", in: folders.legacyCaches("Client", bundleID: bundle))
        try scratch.write("newer", "messages.sqlite", in: folders.caches("Client", bundleID: bundle))
        #expect(move.moveCaches("Server", bundleID: bundle))
        #expect(scratch.read("messages.sqlite", in: folders.caches("Server", bundleID: bundle)) == "server")
        #expect(scratch.read("messages.sqlite-wal", in: folders.caches("Server", bundleID: bundle)) == "wal")
        #expect(!move.moveCaches("Client", bundleID: bundle))
        #expect(scratch.read("messages.sqlite", in: folders.caches("Client", bundleID: bundle)) == "newer")
        // The bundle's folder in Application Support, emptied, is gone.
        #expect(!FileManager.default.fileExists(atPath: folders.legacyCaches("Server", bundleID: bundle).deletingLastPathComponent().path))
    }

    @Test func theLogsMoveOrAreAddedToTheVolumes() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        let folders = scratch.folders
        try scratch.write("server 1\n", "Visor-server.log", in: folders.legacyLogs)
        try scratch.write("proxy 1\n", "Visor-agent-proxy.log", in: folders.legacyLogs)
        try scratch.write("proxy 0\n", "Visor-agent-proxy.log", in: folders.logs)
        try scratch.write("not Visor's\n", "Other.log", in: folders.legacyLogs)
        let moved = VisorFolderMove(folders: folders, answers: { _ in false }).moveLogs()
        #expect(moved == ["Visor-server.log", "Visor-agent-proxy.log"])
        #expect(scratch.read("Visor-server.log", in: folders.logs) == "server 1\n")
        #expect(scratch.read("Visor-agent-proxy.log", in: folders.logs) == "proxy 0\nproxy 1\n")
        #expect(!scratch.exists("Visor-server.log", in: folders.legacyLogs))
        #expect(scratch.exists("Other.log", in: folders.legacyLogs))
    }
}
