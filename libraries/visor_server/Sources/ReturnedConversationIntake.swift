// A handed-back session's conversation as its runner's wrapper returns it
// (agent_protocol's AgentDriver.ReturnConversation, taken by VisorDriver's
// DriverService), held to #444's rules for a move here
// (VisorServer+MigrationContainment, VisorServer+MigrationSize): its places
// are the runner's words, never trusted.
//
// - Only Claude's, and only that conversation's files: a place is exactly
//   `projects/<key>/<session>.jsonl`, or under `projects/<key>/<session>/`
//   or `projects/<key>/memory/`, where `<key>` is the header's working
//   directory as the wrapper keys it (every character but an ASCII letter
//   or digit as `-`) and `<session>` the header's session id (a UUID). No
//   absolute place, no `.`, `..` or empty part, a place once.
// - Re-keyed: each goes under the session's own project folder here, the
//   key of the folder it moves back to (HandBackTarget.key), and nowhere
//   else.
// - Staged first: written into a fresh folder of its own inside that
//   project folder (`.visor-handback-<uuid>`), held to a move's caps as it
//   comes (each file, all of them, how many, and the room left free), and
//   only once whole put in place (Staged.place). Refused past any of them,
//   nothing is written: the staging folder goes, and any folder made for it.
// - No link already here is followed: every part of every path below
//   Claude's folder is looked at without following it (FileManager's
//   attributesOfItem, an lstat), and one that is a link, or not a folder
//   where a folder is wanted, is a refusal before anything is moved.
// - Nothing is written over: a file here already that is shorter than the
//   one returned is set aside (`<name>.before-handback-<time>`), never
//   removed; one as long or longer is left as it is.

import Foundation
import VisorAgent

package final class ReturnedConversationIntake {
    /// Why a returned conversation, or a piece of it, isn't taken.
    package struct Refusal: Error, Equatable, CustomStringConvertible {
        package enum Kind: Equatable, Sendable {
            /// A place, or the header, outside what a hand-back returns.
            case unsafe
            /// Past a cap on a file, on all of them, or on how many.
            case tooLarge
            /// More than the disk here has room for, with the margin.
            case noRoom
            /// The disk here wouldn't take it.
            case unwritable
            /// The move back ended before it was put in place.
            case ended
        }

        package let kind: Kind
        package let why: String

        package init(_ kind: Kind, _ why: String) {
            self.kind = kind
            self.why = why
        }

        package var description: String { why }
    }

    /// What was taken, whole, in its staging folder: put in place by the
    /// server once it knows the move back still waits for it
    /// (VisorServer.placeReturned).
    package struct Staged: Sendable {
        package let target: HandBackTarget
        /// The harness's session id the conversation is ("": none).
        package let sessionID: String
        /// Where it was staged, inside the project folder; nil when nothing
        /// came (a header alone).
        package let staging: URL?
        /// Each file by its path under the project folder
        /// (`<session>.jsonl`, `<session>/…`, `memory/…`), as staged.
        package let files: [String]
        /// The folders made for the staging (Claude's folder, `projects`,
        /// the project's), outermost first: removed again if left empty.
        package let made: [URL]

        /// What was done with each file.
        package struct Placement: Equatable, Sendable {
            /// Put where nothing was.
            package var placed: [String] = []
            /// Put in place of a shorter one, which was set aside.
            package var replaced: [String] = []
            /// Left alone: what is here is as long or longer.
            package var kept: [String] = []
            /// The conversation `claude --resume` finds here now: the
            /// session id, when its transcript is in the project folder.
            package var conversation: String?
        }

        /// Every file put in place, or left for what is here: checked
        /// whole first (every folder on the way, and what is at each
        /// place, looked at without following a link), then moved. `stamp`
        /// names what is set aside. The staging folder goes either way.
        package func place(stamp: String) throws -> Placement {
            defer { discard() }
            let files = FileManager.default
            let project = target.project
            var placement = Placement()
            guard let staging else {
                placement.conversation = transcriptHere()
                return placement
            }
            enum Step { case place, aside, keep }
            var steps: [(relative: String, step: Step)] = []
            guard ReturnedConversationIntake.kind(of: project) == .folder else {
                throw Refusal(.unsafe, "\(project.path) is not a folder")
            }
            for relative in self.files {
                let parts = relative.split(separator: "/").map(String.init)
                var at = project
                for folder in parts.dropLast() {
                    at = at.appendingPathComponent(folder, isDirectory: true)
                    switch ReturnedConversationIntake.kind(of: at) {
                    case .missing, .folder: continue
                    default: throw Refusal(.unsafe, "\(at.path) is here already, and is not a folder")
                    }
                }
                let destination = project.appendingPathComponent(relative, isDirectory: false)
                let staged = staging.appendingPathComponent(relative, isDirectory: false)
                switch ReturnedConversationIntake.kind(of: destination) {
                case .missing: steps.append((relative, .place))
                case .file:
                    let shorter = ReturnedConversationIntake.size(of: destination) < ReturnedConversationIntake.size(of: staged)
                    steps.append((relative, shorter ? .aside : .keep))
                default: throw Refusal(.unsafe, "\(destination.path) is here already, and is not a file")
                }
            }
            for (relative, step) in steps {
                let destination = project.appendingPathComponent(relative, isDirectory: false)
                let staged = staging.appendingPathComponent(relative, isDirectory: false)
                do {
                    switch step {
                    case .keep:
                        placement.kept.append(relative)
                        continue
                    case .aside:
                        try files.moveItem(at: destination, to: Self.aside(destination, stamp: stamp))
                        placement.replaced.append(relative)
                    case .place:
                        var at = project
                        for folder in relative.split(separator: "/").dropLast() {
                            at = at.appendingPathComponent(String(folder), isDirectory: true)
                            if ReturnedConversationIntake.kind(of: at) == .missing {
                                try files.createDirectory(at: at, withIntermediateDirectories: false)
                            }
                        }
                        placement.placed.append(relative)
                    }
                    try files.moveItem(at: staged, to: destination)
                } catch {
                    throw Refusal(.unwritable, "\(destination.path) couldn't be put in place: \(error.localizedDescription)")
                }
            }
            placement.conversation = transcriptHere()
            return placement
        }

        /// The session id, when its transcript is in the project folder.
        private func transcriptHere() -> String? {
            guard !sessionID.isEmpty else { return nil }
            let transcript = target.project.appendingPathComponent(sessionID + ".jsonl", isDirectory: false)
            return ReturnedConversationIntake.kind(of: transcript) == .file ? sessionID : nil
        }

        /// Where a file here is set aside: beside it, as
        /// `<name>.before-handback-<stamp>` (and `-2`, `-3`… if that is
        /// taken).
        static func aside(_ url: URL, stamp: String) -> URL {
            let base = url.lastPathComponent + ".before-handback-" + stamp
            var name = base
            var count = 1
            while ReturnedConversationIntake.kind(of: url.deletingLastPathComponent().appendingPathComponent(name)) != .missing {
                count += 1
                name = base + "-\(count)"
            }
            return url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
        }

        /// The staging folder removed, and the folders made for it if they
        /// are empty again.
        package func discard() {
            if let staging { VisorServer.removeTree(staging) }
            for folder in made.reversed() {
                guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true else { continue }
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    let target: HandBackTarget
    let sessionID: String
    /// The runner's key for the session's working directory there.
    let runnerKey: String
    private var staging: URL?
    private var made: [URL] = []
    /// The file being written: its path under the project folder, its
    /// handle, and how much of it has come.
    private var writing: (relative: String, handle: FileHandle, size: Int)?
    private var done: [String] = []
    private var total = 0

    /// A returned conversation whose header says it is `harness`'s (Claude's
    /// alone, "" taken as Claude), worked in `workingDirectory` on the
    /// runner, as `sessionID` ("" for a harness that never said one, and
    /// then no file may follow). Refused for any other header.
    package init(target: HandBackTarget, harness: String, workingDirectory: String, sessionID: String) throws {
        guard harness.isEmpty || harness == "claude" else { throw Refusal(.unsafe, "it is \(harness)'s, and only Claude's conversations are returned") }
        guard sessionID.isEmpty || SessionCatalog.isConversationID(sessionID) else {
            throw Refusal(.unsafe, "its session id, “\(sessionID)”, is not one Claude makes")
        }
        guard VisorServer.isPlainPath(workingDirectory) else { throw Refusal(.unsafe, "its working directory, \(workingDirectory), is not a full path") }
        guard !target.key.isEmpty, !target.key.contains("/"), target.key != ".", target.key != ".." else {
            throw Refusal(.unsafe, "the folder it moves back to has no key Claude keeps it under")
        }
        self.target = target
        self.sessionID = sessionID
        runnerKey = Self.runnerKey(for: workingDirectory)
    }

    /// The key the wrapper keeps a working directory's conversations under
    /// on its runner (agent_protocol's ConversationReturn.projectKey): the
    /// path as the header gives it (the runner's links aren't this
    /// computer's to follow), every character but an ASCII letter or digit
    /// as "-".
    package static func runnerKey(for workingDirectory: String) -> String {
        String(workingDirectory.unicodeScalars.map { scalar -> Character in
            let ascii = scalar.isASCII && (("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar))
            return ascii ? Character(scalar) : "-"
        })
    }

    /// The path under the project folder a returned place goes to: nil for
    /// one a hand-back doesn't return.
    package func relative(of place: String) -> String? {
        guard !place.hasPrefix("/"), !place.contains("\0") else { return nil }
        let parts = place.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "projects", parts[1] == runnerKey,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let rest = Array(parts.dropFirst(2))
        let shaped = rest == [sessionID + ".jsonl"] || (rest.count >= 2 && (rest[0] == sessionID || rest[0] == "memory"))
        return shaped ? rest.joined(separator: "/") : nil
    }

    /// A piece of a file: the first of its place starts it, each next one
    /// follows on, and `last` ends it. A file's pieces come together, and a
    /// place once.
    package func take(place: String, data: Data, last: Bool) throws {
        guard !sessionID.isEmpty else { throw Refusal(.unsafe, "it sends files for no session") }
        if let writing, writing.relative != relative(of: place) {
            throw Refusal(.unsafe, "\(place) began before \(writing.relative) had ended")
        }
        if writing == nil { try begin(place) }
        guard var file = writing else { return }
        let limits = target.limits
        guard file.size + data.count <= limits.fileBytes else {
            throw Refusal(.tooLarge, "\(place) is more than the \(VisorServer.megabytes(limits.fileBytes)) a file may be")
        }
        guard total + data.count <= limits.totalBytes else {
            throw Refusal(.tooLarge, "its files come to more than the \(VisorServer.megabytes(limits.totalBytes)) a conversation may")
        }
        if let free = target.free, total + data.count + limits.freeMargin > free {
            throw Refusal(.noRoom, "\(target.claudeFolder.path) has \(VisorServer.megabytes(free)) free, and its files need more than "
                + "\(VisorServer.megabytes(total + data.count)) with \(VisorServer.megabytes(limits.freeMargin)) to spare")
        }
        do { try file.handle.write(contentsOf: data) } catch {
            throw Refusal(.unwritable, "\(place) couldn't be written: \(error.localizedDescription)")
        }
        file.size += data.count
        total += data.count
        writing = file
        guard last else { return }
        try? file.handle.close()
        done.append(file.relative)
        writing = nil
    }

    /// A new file at `place`, in the staging folder (made with the first).
    private func begin(_ place: String) throws {
        guard let relative = relative(of: place) else {
            throw Refusal(.unsafe, "it would put a file at \(place), which is not where Claude keeps this conversation")
        }
        guard !done.contains(relative) else { throw Refusal(.unsafe, "it sends \(place) twice") }
        guard done.count < target.limits.files else { throw Refusal(.tooLarge, "it sends more than the \(target.limits.files) files a conversation may") }
        let staging = try stagingFolder()
        let parts = relative.split(separator: "/").map(String.init)
        var at = staging
        for folder in parts.dropLast() {
            at = at.appendingPathComponent(folder, isDirectory: true)
            switch Self.kind(of: at) {
            case .folder: continue
            case .missing:
                guard (try? FileManager.default.createDirectory(at: at, withIntermediateDirectories: false)) != nil else {
                    throw Refusal(.unwritable, "\(at.path) couldn't be made")
                }
            default: throw Refusal(.unsafe, "\(place) is under a file it sent")
            }
        }
        let url = staging.appendingPathComponent(relative, isDirectory: false)
        guard Self.kind(of: url) == .missing,
              FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o600)]),
              Self.kind(of: url) == .file, let handle = FileHandle(forWritingAtPath: url.path) else {
            throw Refusal(.unwritable, "\(place) couldn't be staged")
        }
        writing = (relative, handle, 0)
    }

    /// The staging folder: made, with whatever folder on the way to it
    /// isn't here yet (each looked at without following a link: Claude's
    /// folder's `projects`, then the project's).
    private func stagingFolder() throws -> URL {
        if let staging { return staging }
        let projects = target.claudeFolder.appendingPathComponent("projects", isDirectory: true)
        for folder in [target.claudeFolder, projects, target.project] {
            switch Self.kind(of: folder) {
            case .folder: continue
            case .missing:
                // Claude's folder with whatever is missing above it (it is
                // this computer's own, as Visor's agents take it); below
                // it, a folder at a time.
                let above = folder == target.claudeFolder
                guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: above)) != nil else {
                    throw Refusal(.unwritable, "\(folder.path) couldn't be made")
                }
                made.append(folder)
            case .link where folder == target.claudeFolder: continue
            default: throw Refusal(.unsafe, "\(folder.path) is not a folder")
            }
        }
        let folder = target.project.appendingPathComponent(".visor-handback-" + UUID().uuidString.lowercased(), isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil else {
            throw Refusal(.unwritable, "\(folder.path) couldn't be made")
        }
        staging = folder
        return folder
    }

    /// Everything taken, whole: refused when a file hasn't had its last
    /// piece.
    package func finish() throws -> Staged {
        if let writing { throw Refusal(.unsafe, "\(writing.relative) ended before its last piece") }
        return Staged(target: target, sessionID: sessionID, staging: staging, files: done, made: made)
    }

    /// What was staged removed, and the folders made for it if empty: for
    /// a return refused, or one whose call ended part way.
    package func discard() {
        if let writing { try? writing.handle.close() }
        writing = nil
        Staged(target: target, sessionID: sessionID, staging: staging, files: done, made: made).discard()
    }

    enum Kind: Equatable { case missing, file, folder, link, other }

    /// What is at `url`, a link not followed (FileManager's attributes are
    /// an lstat's): Claude's folder itself may be a link the person made,
    /// and stagingFolder lets that one alone be.
    static func kind(of url: URL) -> Kind {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { return .missing }
        switch type {
        case .typeRegular: return .file
        case .typeDirectory: return .folder
        case .typeSymbolicLink: return .link
        default: return .other
        }
    }

    static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
