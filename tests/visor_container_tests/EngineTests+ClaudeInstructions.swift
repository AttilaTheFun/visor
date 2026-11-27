// The Sessions container's Claude's CLAUDE.md (ContainerClaudeInstructions;
// docs/containers.md, "Its Claude's instructions"; Logan, 26 Nov 2026):
// made at a boot when there's none, importing the checkouts' AGENTS.md;
// one there already (Manager's) never written over, nor a link by its
// name; and none made while no checkouts' folder is shared.

import Foundation
import Testing
import VisorContainerCore

extension EngineTests {
    @Test func itsClaudesInstructionsAreMadeAtItsBootWhenThereAreNone() async throws {
        let rig = try await rig()
        defer { rig.remove() }
        let sessions = rig.root.appendingPathComponent("Sessions", isDirectory: true)
        let folder = sessions.appendingPathComponent(".claude", isDirectory: true)
        let instructions = ContainerClaudeInstructions(folder: folder.path, checkouts: "/Volumes/Sources")
        rig.change { $0.claudeInstructions = instructions }
        let engine = rig.engine(sessions: sessions.path)
        let status = await engine.start()
        #expect(status.state == .running, "\(status.errors)")
        let text = try String(contentsOf: instructions.file, encoding: .utf8)
        #expect(text.hasPrefix("@/Volumes/Sources/AGENTS.md\n"), "the checkouts' AGENTS.md imported: \(text)")
        #expect(text.contains("# In the Sessions container") && text.contains("Nothing is cloned for you"))
        #expect(text.contains(sessions.path), "where its folder is")
        _ = await engine.stop()
        // Its next boot leaves it as it is, changed or not.
        try Data("mine\n".utf8).write(to: instructions.file)
        _ = await engine.start()
        #expect(try String(contentsOf: instructions.file, encoding: .utf8) == "mine\n")
        _ = await engine.stop()
    }

    @Test func oneThereAlreadyIsNeverWrittenOver() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-instructions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let instructions = ContainerClaudeInstructions(folder: folder.path, checkouts: "/Volumes/Sources")
        try Data("Manager's own\n".utf8).write(to: instructions.file)
        var said: [String] = []
        instructions.write { said.append($0) }
        #expect(try String(contentsOf: instructions.file, encoding: .utf8) == "Manager's own\n")
        #expect(said.isEmpty, "\(said)")
        // A link by its name, even one that leads nowhere, is left too.
        try FileManager.default.removeItem(at: instructions.file)
        try FileManager.default.createSymbolicLink(atPath: instructions.file.path, withDestinationPath: folder.path + "/nowhere.md")
        instructions.write { said.append($0) }
        #expect(!FileManager.default.fileExists(atPath: folder.path + "/nowhere.md") && said.isEmpty, "\(said)")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() == ["CLAUDE.md"], "nothing staged left")
    }

    @Test func noneIsMadeWhileNoCheckoutsFolderIsShared() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-instructions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let none = ContainerClaudeInstructions(folder: folder.path, checkouts: nil)
        var said: [String] = []
        none.write { said.append($0) }
        #expect(!FileManager.default.fileExists(atPath: none.file.path) && said.isEmpty)
        let some = ContainerClaudeInstructions(folder: folder.path, checkouts: "/Volumes/Work")
        some.write { said.append($0) }
        #expect(try String(contentsOf: some.file, encoding: .utf8).hasPrefix("@/Volumes/Work/AGENTS.md\n"))
        #expect(said == ["container: \(some.file.path) made, importing /Volumes/Work/AGENTS.md"])
        #expect((try FileManager.default.contentsOfDirectory(atPath: folder.path)).sorted() == ["CLAUDE.md"], "nothing staged left")
    }
}
