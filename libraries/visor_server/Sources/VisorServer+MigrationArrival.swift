// A session moving here from another server (VisorServer+Migration.swift):
// what will be done with each of its projects, the files the client
// carries written a piece at a time, projects cloned or unpacked, and at
// the end the conversation's files put where the agent here looks for
// them and the session started on the same conversation.

import Foundation
import VisorProtocol

extension VisorServer {
    /// What this server will do with the session offered (`offer`): where
    /// it runs here — the same place under this home folder — and for each
    /// project whether it is here already, is cloned, copied, or made.
    func migrationPlan(_ body: Envelope) async -> Envelope {
        ageMigrations()
        guard let offer = body.offer, let harness = harnesses.harness(for: offer.session.agent), !offer.session.agent.isShell else {
            return .error("This server does not run that kind of session.")
        }
        let home = SessionCatalog.home.path
        let here = { (path: String) -> String in Self.path(path, from: offer.home, to: home) }
        let most = offer.projects.dropFirst().map(\.mentions).max() ?? 0
        var steps: [MigrationStep] = []
        for (index, project) in offer.projects.enumerated() {
            let path = here(project.path)
            var step = await Self.step(for: project, at: path)
            // The session's own folder always; the others it works in
            // most, unless the user says not.
            step.chosen = index == 0 || step.action == .present || (project.mentions >= 3 && project.mentions * 10 >= most)
            steps.append(step)
        }
        let id = UUID().uuidString.lowercased()
        let plan = MigrationPlan(id: id, cwd: here(offer.session.cwd), agentInstalled: harness.available, steps: steps)
        let folder = Self.migrationsFolder.appendingPathComponent("in-" + id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        migrationsIn[id] = IncomingMigration(offer: offer, plan: plan, folder: folder, created: Date())
        var e = Envelope(type: "migration")
        e.plan = plan
        return e
    }

    /// A project as it will be here.
    private static func step(for project: MigrationProject, at path: String) async -> MigrationStep {
        var step = MigrationStep(project: project.path, path: path, action: .present, note: "", chosen: false)
        if FileManager.default.fileExists(atPath: path) {
            guard let theirs = project.commit else {
                step.note = "Here already."
                return step
            }
            let ours = await ProjectSurvey.git(["rev-parse", "HEAD"], in: path)
            step.note = switch ours {
            case nil: "Here already, though not as a git repository."
            case theirs: "Here already, at the same commit."
            default: "Here already, at another commit (\(ours?.prefix(7) ?? "") here, \(theirs.prefix(7)) there)."
            }
        } else if project.isRepository, let remote = project.remote, !project.unshared {
            step.action = .clone
            step.note = "Cloned from \(remote)\(project.branch.map { " (\($0))" } ?? "")."
        } else if project.isRepository {
            step.action = .copy
            let why = project.remote == nil ? "it has no remote" : "it has changes or commits its remote does not"
            step.note = "Copied across, \(Self.megabytes(project.size)): \(why)."
        } else {
            step.action = .create
            step.note = "Made here, empty."
        }
        return step
    }

    /// A piece of a file the client carries (`migration`, `file`), at
    /// `offset`: the first piece starts it, each next one follows on.
    func migrationWrite(_ body: Envelope) -> Envelope {
        guard let id = body.migration, let move = migrationsIn[id] else { return .error("That move has ended; start it again.") }
        guard let file = body.file?.id, !file.contains("/"), !file.hasPrefix("."), let data = body.data.flatMap({ Data(base64Encoded: $0) }) else {
            return .error("A file and its bytes are required")
        }
        let url = move.folder.appendingPathComponent(file, isDirectory: false)
        let offset = body.offset ?? 0
        if offset == 0 { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard Self.fileSize(url) == offset, let handle = try? FileHandle(forWritingTo: url) else {
            return .error("That piece does not follow on from what was written (\(Self.fileSize(url)) bytes).")
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return .error("Could not write: \(error.localizedDescription)")
        }
        var e = Envelope(type: "migration")
        e.offset = offset + data.count
        return e
    }

    /// Clones the project of a step the plan said to clone (`steps`).
    func migrationClone(_ body: Envelope) async -> Envelope {
        guard let id = body.migration, let move = migrationsIn[id] else { return .error("That move has ended; start it again.") }
        guard let step = body.steps?.first, let planned = move.plan.steps.first(where: { $0.path == step.path }),
              let project = move.offer.projects.first(where: { $0.path == planned.project }), let remote = project.remote else {
            return .error("That project is not one to clone.")
        }
        guard !FileManager.default.fileExists(atPath: planned.path) else { return .error("\(planned.path) is here already.") }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: planned.path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let git = ToolPath.resolve("git") ?? "/usr/bin/git"
        var arguments = ["clone"]
        if let branch = project.branch { arguments += ["--branch", branch] }
        guard let result = await Command.output(git, arguments + [remote, planned.path], environment: ToolPath.environment(), errors: true) else {
            return .error("git could not be started")
        }
        guard result.status == 0 else {
            try? FileManager.default.removeItem(atPath: planned.path)
            return .error("Could not clone \(remote): \(result.text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return Envelope(type: "migration")
    }

    /// Unpacks a project the client carried (`file`) where its step says
    /// (`steps`): somewhere with nothing there yet.
    func migrationUnpack(_ body: Envelope) async -> Envelope {
        guard let id = body.migration, let move = migrationsIn[id] else { return .error("That move has ended; start it again.") }
        guard let step = body.steps?.first, let planned = move.plan.steps.first(where: { $0.path == step.path }),
              let file = body.file?.id, !file.contains("/") else { return .error("That project is not one to copy.") }
        let archive = move.folder.appendingPathComponent(file, isDirectory: false)
        let target = URL(fileURLWithPath: planned.path, isDirectory: true)
        if let inside = try? FileManager.default.contentsOfDirectory(atPath: target.path), !inside.isEmpty {
            return .error("\(planned.path) is here already.")
        }
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let tar = ToolPath.resolve("tar") ?? "/usr/bin/tar"
        guard let result = await Command.output(tar, ["-xzf", archive.path, "-C", target.path], errors: true) else { return .error("tar could not be started") }
        try? FileManager.default.removeItem(at: archive)
        guard result.status == 0 else { return .error("Could not unpack \(planned.path): \(result.text)") }
        return Envelope(type: "migration")
    }

    /// The end of a move: the conversation's files put where the agent here
    /// looks for them, the folders the chosen steps make (`steps`), and
    /// the session started on the same conversation, told where it came
    /// from. The new session's id is in `session`.
    func migrationFinish(_ body: Envelope) async -> Envelope {
        guard let id = body.migration, let move = migrationsIn[id] else { return .error("That move has ended; start it again.") }
        let offer = move.offer, plan = move.plan
        let files = FileManager.default
        let chosen = Set((body.steps ?? []).map(\.path))
        for step in plan.steps where step.action == .create && chosen.contains(step.path) {
            try? files.createDirectory(atPath: step.path, withIntermediateDirectories: true)
        }
        try? files.createDirectory(atPath: plan.cwd, withIntermediateDirectories: true)
        for file in offer.files where !file.place.isEmpty {
            let carried = move.folder.appendingPathComponent(file.id, isDirectory: false)
            guard Self.fileSize(carried) == file.size else { return .error("Not all of the conversation was carried here; start the move again.") }
            guard let destination = SessionCatalog.destination(of: file.place, agent: offer.session.agent, cwd: plan.cwd) else {
                return .error("Nowhere to put \(file.place)")
            }
            try? files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.removeItem(at: destination)
            if file.packed {
                let tar = ToolPath.resolve("tar") ?? "/usr/bin/tar"
                _ = await Command.output(tar, ["-xzf", carried.path, "-C", destination.deletingLastPathComponent().path], errors: true)
            } else {
                do { try files.moveItem(at: carried, to: destination) } catch {
                    return .error("Could not put the conversation at \(destination.path): \(error.localizedDescription)")
                }
            }
        }
        var start = Envelope(type: "start")
        start.id = Self.newSessionID()
        start.agent = offer.session.agent
        start.cwd = plan.cwd
        start.title = offer.session.title
        start.skipPermissions = offer.session.skipPermissions
        start.resume = offer.resumeID
        perform(start, from: nil)
        guard let record = session(start.id) else { return .error("The session could not be started here.") }
        record.setSettings(model: offer.session.model, effort: offer.session.effort)
        var notice = "Moved here from \(offer.from.isEmpty ? "another computer" : offer.from). The session there is as it was: remove it once this one works."
        if let goal = offer.session.goal, !goal.isEmpty, record.process.carryGoal(goal) {
            notice += " Its goal came too, paused: /goal resume carries on with it."
        }
        broadcast(record.apply(.notice(notice)), session: record)
        Self.log("session moved here from \(offer.from): \(offer.session.title) (\(record.info.id))")
        saveArchive()
        broadcastSessions()
        try? files.removeItem(at: move.folder)
        migrationsIn[id] = nil
        var e = Envelope(type: "migration")
        e.session = record.info.id
        e.sessions = sessions.map(\.info)
        return e
    }

    /// `path` from a computer whose home folder is `from`, on this one
    /// whose home folder is `to`: under the one, under the other.
    static func path(_ path: String, from: String, to: String) -> String {
        guard !from.isEmpty else { return path }
        if path == from { return to }
        return path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : path
    }

    /// A session's id as clients make them: 24 letters and digits.
    static func newSessionID() -> String {
        String((0..<24).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    /// "340 KB", "12.5 MB", "1.3 GB".
    static func megabytes(_ bytes: Int) -> String {
        guard bytes >= 1 << 20 else { return "\(max(1, bytes >> 10)) KB" }
        let (unit, shift) = bytes >= 1 << 30 ? ("GB", 30) : ("MB", 20)
        let tenths = (bytes * 10 + (1 << (shift - 1))) >> shift
        return "\(tenths / 10).\(tenths % 10) \(unit)"
    }
}
