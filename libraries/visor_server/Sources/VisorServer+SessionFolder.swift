// A session given another working directory from its inspector (`POST
// /api/sessions/<id>/folder {path}`): its agent ended, its own files moved
// to the new folder's keeping (FolderMove+Session), its record given the
// folder, and its agent resumed there on the same conversation.
//
// Refused, with nothing changed, while its turn isn't idle, while its agent
// runs elsewhere (driven: the Sessions container or a runner), while it's
// archived, during an update's watch (RelaunchWatchLock), and for a folder
// that isn't one it can be given (FolderMove.checkFolder). A move whose
// files can't be moved deletes nothing (FolderMove+Session), and its agent
// is resumed where it was.

import Foundation
import VisorAgent
import VisorProtocol
import VisorSystem

extension VisorServer {
    /// Why the session can't be given another folder now, or nil.
    func folderChangeRefused(_ record: SessionRecord) -> String? {
        let name = "“\(record.displayName)”"
        if record.info.archived { return "\(name) is archived: unarchive it first." }
        if record.driven { return "\(name)'s agent runs elsewhere (its container or a runner): move it back to this computer first." }
        if let watched = relaunchWatched() { return watched }
        if record.info.busy || !record.currentTurn.isIdle {
            return "\(name) is working: wait for it to finish, then change its folder."
        }
        if record.held || record.info.agentState == .starting || record.info.agentState == .stopping {
            return "\(name)'s agent is starting or stopping: wait for it to finish, then change its folder."
        }
        return nil
    }

    /// The move of a session's agent's files to `folder`, in this computer's
    /// agents' home (the user's, unless a test says).
    func folderMove(to folder: String) -> FolderMove {
        FolderMove(target: folder, home: SessionCatalog.home, data: HostFolders.dataFolder, openRouter: SessionCatalog.openrouterRoot)
    }

    /// Gives the session `path` for its working directory: its agent ended
    /// (stopping meanwhile), its conversation and what goes with it moved
    /// (FolderMove+Session), its record given the folder and kept, and its
    /// agent made again there on the same conversation, and started unless
    /// it was stopped. What went wrong, or nil once it's there. A move that
    /// fails leaves the session where it was, its agent resumed there.
    func moveFolder(_ record: SessionRecord, to path: String) async -> String? {
        if let refusal = folderChangeRefused(record) { return refusal }
        let from = record.info.cwd
        let folder: String
        do { folder = try FolderMove.checkFolder(path, from: from) } catch {
            return Self.folderProblem(error)
        }
        let id = record.info.id
        let stopped = record.info.agentState == .stopped
        let resume = record.process.resumeID
        Self.log("moving \(record.info.title) (\(id)) from \(from) to \(folder): ending its agent")
        // The agent goes first, as a restart's does: one made for the folder
        // it's in stands in, not started, and what is said meanwhile waits.
        setAgentState(record, .stopping)
        record.held = true
        record.restartWhenIdle = false
        let old = record.process
        record.replaceProcess(makeProcess(record.info, resume: resume))
        await old.end(within: .seconds(3))
        noteAgentWent(record)
        // Ended or archived while its agent went: nothing more to do.
        guard sessions.contains(where: { $0 === record }), !record.info.archived else {
            Self.log("moving \(record.info.title) (\(id)): it ended or was archived meanwhile; not moved")
            release(record)
            return "“\(record.displayName)” ended or was archived meanwhile: its folder is as it was."
        }
        let others = sessions.filter { $0 !== record }.map(\.info)
        let move = folderMove(to: folder)
        let info = record.info
        do {
            // Off the main actor: memory merged file by file can take a moment.
            let (planned, done) = try await Task.detached {
                let plan = try move.planSession(info, resumeID: resume, others: others)
                let done = try move.applySession(plan)
                return (FolderMove.describe(plan), done)
            }.value
            for line in planned + done { Self.log("moving \(info.title) (\(id)): \(line.trimmingCharacters(in: .whitespaces))") }
        } catch {
            let said = Self.folderProblem(error)
            Self.log("moving \(info.title) (\(id)) to \(folder) failed, resuming it in \(from): \(said)")
            // Nothing was deleted: its agent is made again where it was, its
            // conversation found there (linked back into the old folder's
            // project if it had gone: makeProcess's adoptHistory).
            resumeAfterFolderChange(record, resume: resume, stopped: stopped)
            return "Its folder wasn't changed: \(said)"
        }
        record.info = FolderMove.moved(record.info, to: folder)
        Self.log("moved \(record.info.title) (\(id)) to \(folder): its record kept, resuming its agent there")
        saveArchiveNow()
        resumeAfterFolderChange(record, resume: resume, stopped: stopped)
        return nil
    }

    /// A move's error in words for the person: FolderMoveError's own, or
    /// the system's.
    static func folderProblem(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The session's agent made again in its folder as the record has it
    /// now, on the conversation `resume`, and started unless it was stopped;
    /// its file followed where it is now, and what waited goes over.
    private func resumeAfterFolderChange(_ record: SessionRecord, resume: String?, stopped: Bool) {
        record.replaceProcess(makeProcess(record.info, resume: resume))
        record.followFile()
        if stopped {
            setAgentState(record, .stopped)
        } else {
            launchAgent(record)
        }
        release(record)
        saveArchiveNow()
        broadcastSessions()
    }

    /// `POST /api/sessions/<id>/folder {path}`: the session, once its agent
    /// has started in its new folder. 409 with `error` while it can't move
    /// (mid-turn, driven, archived, an update's watch); 400 for a folder it
    /// can't be given, or a move that failed (its agent resumed where it
    /// was).
    func restMoveFolder(_ call: RESTCall) async -> HTTPResponse {
        guard let record = session(call.parts[1]) else { return HTTPResponse(404, "{\"error\":\"no such session\"}") }
        guard let path = call.body.path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return HTTPResponse(400, Envelope.error("A folder is required.").encoded())
        }
        if let refusal = folderChangeRefused(record) { return HTTPResponse(409, Envelope.error(refusal).encoded()) }
        if let problem = await moveFolder(record, to: path) { return HTTPResponse(400, Envelope.error(problem).encoded()) }
        return .json(Envelope.sessions([record.info]).encoded())
    }
}
