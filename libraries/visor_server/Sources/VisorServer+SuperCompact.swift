// Super Compact on the REST side (docs/super-compact.md): a session's
// conversation, too big to move or back up, condensed into HANDOFF.md by
// a job on its server while the session runs on.
//
//   POST   /api/sessions/<id>/super-compact   start one (or carry a failed one on)
//   GET    /api/sessions/<id>/super-compact   how it stands
//   DELETE /api/sessions/<id>/super-compact   cancel it (or discard its handoff)
//   GET|PUT /api/sessions/<id>/super-compact/handoff   HANDOFF.md, to review and edit
//   POST   /api/sessions/<id>/super-compact/cutover   the new session started from it
//                                                     (VisorServer+SuperCompactCutover)
//
// Admin-only, as every REST route is (VisorServer+Access). One job runs
// at a time per server, for its disk and CPU: a second is refused while
// one runs. A job the server went away under carries on when it starts
// again (`resumeSuperCompaction`).

import Foundation
import VisorAgent
import VisorProtocol
import VisorSystem

extension VisorServer {
    /// Where the jobs are kept: `super-compact/<session>/<job>/` in the
    /// data folder.
    static var superCompactRoot: URL { HostFolders.dataFolder.appendingPathComponent("super-compact", isDirectory: true) }

    /// The `claude` the jobs run, when not the one on the tools' path
    /// (tests give a fake one).
    static var superCompactTool: String?

    /// The `claude` a job runs: a test's, else the image's in the Sessions
    /// container while it's on (VisorServer+ContainerClaude), else the one
    /// on the tools' path; nil when there's none.
    func superCompactProgram() -> String? {
        if let tool = Self.superCompactTool { return tool }
        if claudeRunsInContainer, containerClaudeEnvironment() != nil { return "claude" }
        return ToolPath.resolve("claude")
    }

    /// What a second job is told while one runs.
    static func superCompactBusy(_ running: SuperCompactJob) -> String {
        "A super compact is running already, of “\(running.title)” (session \(running.session)): one at a time per server. "
            + "Wait for it to finish, or cancel it (DELETE /api/sessions/\(running.session)/super-compact)."
    }

    func restSuperCompact(_ call: RESTCall) -> HTTPResponse {
        guard let record = session(call.parts[1]) else { return HTTPResponse(404, Envelope.error("No such session").encoded()) }
        switch call.request.method {
        case "POST": return startSuperCompact(record)
        case "GET": return superCompactStatus(record)
        case "DELETE": return cancelSuperCompact(record)
        default: return HTTPResponse(404, "{\"error\":\"not found\"}")
        }
    }

    /// Starts a job on a snapshot of the session's conversation; carries
    /// on the session's last job instead when it failed.
    func startSuperCompact(_ record: SessionRecord) -> HTTPResponse {
        if let running = superCompaction, !running.job.phase.ended {
            return HTTPResponse(409, Envelope.error(Self.superCompactBusy(running.job)).encoded())
        }
        guard record.info.agent == .claude else {
            return HTTPResponse(400, Envelope.error("Super Compact reads Claude Code's conversations: “\(record.info.title)” is \(record.info.agent.title)'s.").encoded())
        }
        guard let tool = superCompactProgram() else {
            return HTTPResponse(400, Envelope.error("Claude Code (claude) is not on this computer, so nothing can run the compaction.").encoded())
        }
        let job: SuperCompactJob
        if var failed = latestSuperCompactJob(of: record.info.id), failed.phase == .failed {
            failed.phase = failed.failedIn ?? .prefilter
            failed.failedIn = nil
            failed.error = nil
            failed.finished = nil
            job = failed
        } else {
            guard let conversation = record.process.resumeID, !conversation.isEmpty else {
                return HTTPResponse(400, Envelope.error("“\(record.info.title)” has no conversation to compact yet.").encoded())
            }
            guard let file = SessionCatalog.conversationFiles(agent: .claude, id: conversation, cwd: record.info.cwd).first(where: { !$0.folder })
            else { return HTTPResponse(404, Envelope.error("The conversation \(conversation) of “\(record.info.title)” is not on this computer.").encoded()) }
            let id = UUID().uuidString.lowercased()
            // Each folder down to the job's its owner's alone (0700).
            let sessionFolder = Self.superCompactRoot.appendingPathComponent(record.info.id, isDirectory: true)
            let folder = sessionFolder.appendingPathComponent(id, isDirectory: true)
            for each in [Self.superCompactRoot, sessionFolder, folder] { SuperCompactJob.makePrivate(each) }
            job = SuperCompactJob(id: id, session: record.info.id, conversation: conversation, title: record.displayName, source: file.url.path,
                                  sourceBytes: Self.wholeLines(of: file.url), folder: folder.path,
                                  settings: settings.superCompact ?? SuperCompactSettings())
        }
        runSuperCompact(job, tool: tool, cwd: record.info.cwd)
        return HTTPResponse(202, superCompaction?.job.json ?? job.json)
    }

    func superCompactStatus(_ record: SessionRecord) -> HTTPResponse {
        if let running = superCompaction, running.job.session == record.info.id { return .json(running.job.json) }
        guard let kept = latestSuperCompactJob(of: record.info.id) else {
            return HTTPResponse(404, Envelope.error("“\(record.info.title)” has had no super compact.").encoded())
        }
        return .json(kept.json)
    }

    func cancelSuperCompact(_ record: SessionRecord) -> HTTPResponse {
        guard let running = superCompaction, running.job.session == record.info.id, !running.job.phase.ended else {
            // A job done and waiting for its review: its handoff discarded.
            if var waiting = latestSuperCompactJob(of: record.info.id), waiting.awaitsReview {
                waiting.discarded = Date().timeIntervalSince1970
                waiting.updated = waiting.discarded ?? waiting.updated
                waiting.keep()
                Self.log("super compact \(waiting.id) of \(record.info.id): its handoff discarded")
                return .json(waiting.json)
            }
            return HTTPResponse(404, Envelope.error("No super compact is running for “\(record.info.title)”.").encoded())
        }
        running.cancel()
        Self.log("super compact \(running.job.id) of \(record.info.id): cancelled")
        return .json(running.job.json)
    }

    /// Runs a job, the one at a time; once it ends, the next one left
    /// unfinished (if any) carries on.
    func runSuperCompact(_ job: SuperCompactJob, tool: String, cwd: String) {
        let compaction = SuperCompaction(job: job, tool: tool, cwd: cwd, caller: Self.superCompactTool == nil ? superCompactCaller() : nil)
        compaction.save()
        compaction.onEnd = { [weak self, weak compaction] _ in
            guard let self, let compaction, self.superCompaction === compaction else { return }
            self.superCompaction = nil
            // Halted (the server going away): nothing else starts now.
            if compaction.stop.asked != .halted { self.resumeSuperCompaction() }
        }
        superCompaction = compaction
        compaction.start()
    }

    /// Carries on the first job left unfinished (the server went away
    /// under it), unless one is running.
    func resumeSuperCompaction() {
        guard superCompaction == nil else { return }
        guard var job = superCompactJobs().filter({ !$0.phase.ended }).min(by: { $0.started < $1.started }) else { return }
        guard let tool = superCompactProgram() else {
            job.failedIn = job.phase
            job.phase = .failed
            job.error = "Claude Code (claude) is not on this computer"
            job.keep()
            return
        }
        Self.log("super compact \(job.id) of \(job.session): carrying on from \(job.phase.rawValue)")
        runSuperCompact(job, tool: tool, cwd: session(job.session)?.info.cwd ?? "")
    }

    /// Stops the job running where it stands, to carry on when the server
    /// is back (it is going away).
    func haltSuperCompaction() {
        guard let running = superCompaction else { return }
        running.halt()
        superCompaction = nil
    }

    /// Every job kept, of every session.
    func superCompactJobs() -> [SuperCompactJob] {
        let files = FileManager.default
        let sessions = (try? files.contentsOfDirectory(at: Self.superCompactRoot, includingPropertiesForKeys: nil)) ?? []
        return sessions.flatMap { folder in
            ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap { SuperCompactJob.kept(in: $0) }
        }
    }

    /// The session's latest job, kept.
    func latestSuperCompactJob(of session: String) -> SuperCompactJob? {
        let folder = Self.superCompactRoot.appendingPathComponent(session, isDirectory: true)
        let jobs = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { SuperCompactJob.kept(in: $0) }
        return jobs.max { $0.started < $1.started }
    }
}
