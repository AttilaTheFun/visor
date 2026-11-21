// Visor's Linux programs copied for the container under the link rule: a
// regular executable, or a relative link with no `/` to one in the same
// folder. Dangling, absolute and escaping links are refused.

import Foundation
import Testing
import VisorContainerCore

@Suite struct ToolsFolderTests {
    private let files = FileManager.default

    /// A folder as the app's Contents/Resources/Linux has it: visor-server,
    /// and relay-client and visor-agent-host links to it.
    private func linuxFolder() throws -> URL {
        let folder = files.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try executable("visor-server", in: folder)
        try files.createSymbolicLink(atPath: folder.appendingPathComponent("relay-client").path, withDestinationPath: "visor-server")
        try files.createSymbolicLink(atPath: folder.appendingPathComponent("visor-agent-host").path, withDestinationPath: "visor-server")
        return folder
    }

    private func executable(_ name: String, in folder: URL, contents: String = "#!/bin/sh\n", mode: Int = 0o755) throws {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try files.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func relink(_ name: String, to target: String, in folder: URL) throws {
        let path = folder.appendingPathComponent(name).path
        try? files.removeItem(atPath: path)
        try files.createSymbolicLink(atPath: path, withDestinationPath: target)
    }

    private func refusal(_ folder: URL) -> ContainerAssetsError? {
        do { try ToolsFolder.check(folder); return nil } catch let error as ContainerAssetsError { return error } catch { return nil }
    }

    @Test func theAppsFolderKeepsTheRule() throws {
        let folder = try linuxFolder()
        defer { try? files.removeItem(at: folder) }
        try ToolsFolder.check(folder)
    }

    @Test func aDanglingLinkIsRefused() throws {
        let folder = try linuxFolder()
        defer { try? files.removeItem(at: folder) }
        try relink("relay-client", to: "visor-servr", in: folder)
        guard case let .toolRefused(name, reason)? = refusal(folder) else { Issue.record("not refused"); return }
        #expect(name == "relay-client")
        #expect(reason.contains("dangling"))
    }

    @Test func anAbsoluteLinkIsRefusedEvenToAProgramThatsThere() throws {
        let folder = try linuxFolder()
        defer { try? files.removeItem(at: folder) }
        try relink("relay-client", to: folder.appendingPathComponent("visor-server").path, in: folder)
        guard case let .toolRefused(name, reason)? = refusal(folder) else { Issue.record("not refused"); return }
        #expect(name == "relay-client")
        #expect(reason.contains("absolute"))
    }

    @Test func anEscapingLinkIsRefused() throws {
        let folder = try linuxFolder()
        defer { try? files.removeItem(at: folder) }
        // Out of the folder, which is all the container's mount holds.
        try relink("relay-client", to: "../visor-server", in: folder)
        guard case let .toolRefused(_, reason)? = refusal(folder) else { Issue.record("not refused"); return }
        #expect(reason.contains("leaves the folder"))
        try relink("relay-client", to: "./visor-server", in: folder)
        #expect(refusal(folder) != nil, "any `/` is refused")
    }

    @Test func aLinkToALinkOrToAFileThatDoesntRunIsRefused() throws {
        let folder = try linuxFolder()
        defer { try? files.removeItem(at: folder) }
        try relink("relay-client", to: "visor-agent-host", in: folder)
        guard case let .toolRefused(_, reason)? = refusal(folder) else { Issue.record("not refused"); return }
        #expect(reason.contains("another link"))
        try relink("relay-client", to: "visor-server", in: folder)
        try executable("notes", in: folder, mode: 0o644)
        guard case let .toolRefused(name, _)? = refusal(folder) else { Issue.record("not refused"); return }
        #expect(name == "notes")
    }

    @Test func aMissingProgramIsSaid() throws {
        let folder = try linuxFolder()
        defer { try? files.removeItem(at: folder) }
        try files.removeItem(at: folder.appendingPathComponent("relay-client"))
        #expect(refusal(folder) == .toolMissing("relay-client"))
    }

    @Test func stagingCopiesTheFolderKeepingItsLinks() throws {
        let source = try linuxFolder()
        let root = files.temporaryDirectory.appendingPathComponent("containers-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? files.removeItem(at: source)
            try? files.removeItem(at: root)
        }
        let layout = ContainerLayout(root: root)
        let staged = try ToolsFolder.stage(from: source, layout: layout, version: "0.64.3")
        #expect(staged.path == root.path + "/tools/0.64.3")
        #expect(try files.destinationOfSymbolicLink(atPath: staged.appendingPathComponent("relay-client").path) == "visor-server")
        try ToolsFolder.check(staged)
        #expect(try files.contentsOfDirectory(atPath: layout.toolsRoot.path) == ["0.64.3"], "nothing half-made is left")
        // The same again: kept. Another build of the same version: copied again.
        try ToolsFolder.stage(from: source, layout: layout, version: "0.64.3")
        try executable("visor-server", in: source, contents: "#!/bin/sh\necho newer\n")
        try ToolsFolder.stage(from: source, layout: layout, version: "0.64.3")
        #expect(try String(contentsOf: staged.appendingPathComponent("visor-server"), encoding: .utf8).contains("newer"))
    }

    @Test func stagingRefusesAFolderThatBreaksTheRule() throws {
        let source = try linuxFolder()
        let root = files.temporaryDirectory.appendingPathComponent("containers-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? files.removeItem(at: source)
            try? files.removeItem(at: root)
        }
        try relink("relay-client", to: "/usr/bin/true", in: source)
        #expect(throws: ContainerAssetsError.self) { try ToolsFolder.stage(from: source, layout: ContainerLayout(root: root), version: "0.64.3") }
        #expect(!files.fileExists(atPath: root.path + "/tools/0.64.3"))
        #expect(throws: ContainerAssetsError.invalidVersion("../x")) {
            try ToolsFolder.stage(from: source, layout: ContainerLayout(root: root), version: "../x")
        }
    }
}
