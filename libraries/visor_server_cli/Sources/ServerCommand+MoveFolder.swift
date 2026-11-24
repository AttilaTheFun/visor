// `visor-server move-folder`: sessions given another working directory with
// their agents' conversations kept (FolderMove), run once with the server
// stopped: the co-tenant's sessions as they move into a primary container
// (Shireworks' docs/volumes.md §6). With `--session <id>`, that one alone,
// as its inspector moves it (FolderMove+Session): what it shares with the
// sessions it leaves is copied.

import Foundation
import VisorServer

extension ServerCommand {
    static let moveFolderUsage = "move-folder --to <folder> [--from <folder>…|--session <id>] [--home <folder>] [--data <folder>] [--dry-run]"

    /// Plans the move and says it; without --dry-run, carries it out and
    /// says what it did.
    @MainActor
    func moveFolder(_ arguments: [String]) throws {
        var to: String?
        var from: [String] = []
        var session: String?
        var home = FileManager.default.homeDirectoryForCurrentUser
        var data = system.dataDirectory
        var dryRun = false
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            if flag == "--dry-run" {
                dryRun = true
                continue
            }
            guard let value = rest.popFirst(), !value.isEmpty else { throw CommandLineError.usage(Self.moveFolderUsage) }
            switch flag {
            case "--to": to = value
            case "--from": from.append(value)
            case "--session": session = value
            case "--home": home = URL(fileURLWithPath: value, isDirectory: true)
            case "--data": data = URL(fileURLWithPath: value, isDirectory: true)
            default: throw CommandLineError.usage(Self.moveFolderUsage)
            }
        }
        guard let to, to.hasPrefix("/") else { throw CommandLineError.usage(Self.moveFolderUsage + ": --to takes an absolute folder") }
        guard from.allSatisfy({ $0.hasPrefix("/") }) else { throw CommandLineError.usage(Self.moveFolderUsage + ": --from takes absolute folders") }
        guard session == nil || from.isEmpty else { throw CommandLineError.usage(Self.moveFolderUsage + ": --from or --session, not both") }
        // Never under a running server: it would write its own records back.
        if let pid = Self.runningServer(in: data, platform: quietPlatform()) {
            throw CommandLineError.failed("a server (process \(pid)) holds \(data.path); stop it first")
        }
        let move = FolderMove(target: to, home: home, data: data, from: from.isEmpty ? nil : from)
        if let session {
            let plan: FolderMove.SessionPlan
            do { plan = try move.planSession(id: session) } catch let error as FolderMoveError {
                throw CommandLineError.failed(error.errorDescription ?? "\(error)")
            }
            for line in FolderMove.describe(plan) { print(line) }
            guard !dryRun else {
                print("Dry run: nothing changed.")
                return
            }
            // Its agent's files first: the record follows only once its
            // conversation is in the new folder's keeping.
            for line in try move.applySession(plan) + move.writeRecord(plan) { print(line) }
            return
        }
        let plan = try move.plan()
        for line in FolderMove.describe(plan, target: move.target) { print(line) }
        guard !dryRun else {
            print("Dry run: nothing changed.")
            return
        }
        for line in try move.apply(plan) { print(line) }
    }

    /// The process the pid file in `data` names, while it runs.
    static func runningServer(in data: URL, platform: ServerPlatform) -> Int32? {
        guard let text = try? String(contentsOf: data.appendingPathComponent("visor-server.pid"), encoding: .utf8),
              let pid = text.split(whereSeparator: \.isWhitespace).first.flatMap({ Int32($0) }), pid > 0 else { return nil }
        return platform.processes.isRunning(pid) ? pid : nil
    }
}
