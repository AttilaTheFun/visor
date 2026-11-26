// Where Claude Code keeps a project's memory (its auto memory,
// code.claude.com/docs/en/memory): <its config folder>/projects/<project>/
// memory, the project named as a folder is (projectDirectoryName), but for
// the git repository the folder is in, its main checkout's top, so that
// every worktree and folder of one repository shares it; outside a
// repository, the folder itself. A conversation is kept under the folder
// Claude Code was started in, so its memory can be under another project
// than its transcript is; and a project's `memory` may be a link to
// another's (Overcast's was, on 26 Nov 2026, and a move took the link alone).
// A link is followed only as far as Claude's projects folder: a memory
// whose real path is outside it is refused, never read (a container's
// agent writes its Claude folder on Sessions, and could point a `memory`
// there at any folder of the Mac's, which a move or a cut-over, running as
// the user, would then carry: NCH, #562).

import Foundation

extension ClaudeSessionFiles {
    /// The project Claude Code keeps the memory of a session in `cwd`
    /// under: its repository's, or its own outside one.
    public static func memoryProjectDirectoryName(for cwd: String) -> String {
        projectDirectoryName(for: repositoryTop(of: cwd) ?? cwd)
    }

    /// The memory of the conversation whose transcript is `conversation`,
    /// of a session in `cwd`: the first with anything in it of the
    /// project's beside the transcript, the one of the folder's repository
    /// and the one of the folder itself. A link to a folder is followed:
    /// the folder it leads to, by its real path, only when that is inside
    /// Claude's projects folder; one leading anywhere else is passed over,
    /// unread, and said to `refused` (its path, never what is in it). Nil
    /// when none has any.
    public static func memoryFolder(conversation: URL?, cwd: String, home: URL = ClaudeSessionFiles.home,
                                    refused: (String) -> Void = { _ in }) -> URL? {
        let root = projectsRoot(home: home)
        let path = (cwd as NSString).expandingTildeInPath
        var projects: [URL] = []
        if let conversation { projects.append(conversation.deletingLastPathComponent()) }
        projects.append(root.appendingPathComponent(memoryProjectDirectoryName(for: path), isDirectory: true))
        projects.append(root.appendingPathComponent(projectDirectoryName(for: path), isDirectory: true))
        let files = FileManager.default
        var asked: Set<String> = []
        for project in projects where asked.insert(project.standardizedFileURL.path).inserted {
            let named = project.appendingPathComponent("memory", isDirectory: true).path
            let memory = realPath(named)
            guard isInsideProjects(memory, home: home) else {
                refused("\(named) leads out of \(root.path), to \(memory): not read")
                continue
            }
            var isFolder: ObjCBool = false
            guard files.fileExists(atPath: memory, isDirectory: &isFolder), isFolder.boolValue,
                  let names = try? files.contentsOfDirectory(atPath: memory), !names.isEmpty else { continue }
            return URL(fileURLWithPath: memory, isDirectory: true)
        }
        return nil
    }

    /// Whether `path`, every link in it followed, is inside Claude's
    /// projects folder (itself, its links followed too), and not that folder.
    public static func isInsideProjects(_ path: String, home: URL = ClaudeSessionFiles.home) -> Bool {
        var root = realPath(projectsRoot(home: home).path)
        if !root.hasSuffix("/") { root += "/" }
        return realPath(path).hasPrefix(root)
    }

    /// The top of the main checkout of the git repository `cwd` is in, as
    /// its `.git` says, without asking git: a folder's, that checkout's
    /// own; a file's (a worktree's, a submodule's), the checkout whose
    /// `.git` its `commondir` names, else the folder the file is in. Nil
    /// outside a repository.
    static func repositoryTop(of cwd: String) -> String? {
        var folder = realPath((cwd as NSString).expandingTildeInPath)
        guard folder.hasPrefix("/") else { return nil }
        while true {
            let dotGit = (folder == "/" ? "" : folder) + "/.git"
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isFolder) {
                return isFolder.boolValue ? folder : mainCheckout(of: dotGit) ?? folder
            }
            if folder == "/" { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    /// The main checkout of the worktree whose `.git` file is `file`
    /// (`gitdir: <its folder in the main .git>`, where `commondir` leads
    /// back to that .git); nil for one that names none (a submodule's).
    private static func mainCheckout(of file: String) -> String? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let named = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitdir = named.hasPrefix("/") ? named : ((file as NSString).deletingLastPathComponent as NSString).appendingPathComponent(named)
        guard let common = try? String(contentsOfFile: gitdir + "/commondir", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !common.isEmpty else { return nil }
        let path = realPath(((common.hasPrefix("/") ? common : (gitdir as NSString).appendingPathComponent(common)) as NSString).standardizingPath)
        guard (path as NSString).lastPathComponent == ".git" else { return nil }
        return (path as NSString).deletingLastPathComponent
    }
}
