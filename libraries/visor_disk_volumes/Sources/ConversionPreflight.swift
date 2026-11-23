// What must be true before a volume is copied or swapped: Visor's server
// and its agents' hosts stopped, and nothing (Spotlight aside) with a file
// open on the volume. Read from `ps` and `lsof`'s output, which Visor Disk
// Utility runs as the person; the reading is here, where it's tested.

import Foundation

public enum ConversionPreflight {
    /// The port Visor's server answers on, on this Mac's loopback.
    public static let serverPort = 7433

    /// The executables that are Visor's server or carry its sessions: the
    /// app's own (the menu bar app, and the server agent launchd runs) and
    /// the agents' hosts, wherever the app is.
    public static let visorExecutables = ["/Visor.app/Contents/MacOS/Visor", "/Visor.app/Contents/Helpers/visor-agent-host"]

    /// Visor's processes in `ps -axo pid=,comm=`'s output: "<pid>
    /// <executable>", a line each.
    public static func visorProcesses(ps output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let space = text.firstIndex(of: " ") else { return nil }
            let executable = text[space...].trimmingCharacters(in: .whitespaces)
            return visorExecutables.contains(where: { executable.hasSuffix($0) }) ? text : nil
        }
    }

    /// Whether a command `lsof` lists is Spotlight's own (`mds`,
    /// `mds_stores`, `mdworker_shared`…), which may read a volume at any
    /// time and lets it go.
    public static func isSpotlight(_ command: String) -> Bool {
        command.hasPrefix("mds") || command.hasPrefix("mdworker")
    }

    /// The processes with a file open on the volume at `mountPoint` in
    /// `lsof -F pcn <mount point>`'s output (`p<pid>`, `c<command>`,
    /// `n<name>` lines): "<command> (<pid>)", each once, in order. Spotlight's
    /// are left aside, and so is a file in the system's own folders at the
    /// root (fseventsd's log, Spotlight's store, revisiond's versions),
    /// which the system holds while the volume is mounted and lets go when
    /// it's unmounted.
    public static func holders(lsof output: String, mountPoint: String) -> [String] {
        var seen: [String] = []
        var pid = "", command = ""
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = value
                command = ""
            case "c":
                command = value
            case "n":
                guard !isSpotlight(command), !isSystemsOwn(value, mountPoint: mountPoint) else { continue }
                let holder = "\(command) (\(pid))"
                if !seen.contains(holder) { seen.append(holder) }
            default:
                continue
            }
        }
        return seen
    }

    /// Whether a path is in one of the system's own folders at the root of
    /// the volume mounted at `mountPoint`.
    static func isSystemsOwn(_ path: String, mountPoint: String) -> Bool {
        VolumeManifest.systemFolders.contains { folder in
            let root = mountPoint + "/" + folder
            return path == root || path.hasPrefix(root + "/")
        }
    }

    /// The refusal for what's running, or nil when nothing is.
    public static func serverRefusal(processes: [String], portAnswers: Bool) -> String? {
        guard !processes.isEmpty || portAnswers else { return nil }
        var what: [String] = []
        if !processes.isEmpty { what.append("Visor's processes are running (\(processes.joined(separator: "; ")))") }
        if portAnswers { what.append("something answers on 127.0.0.1:\(serverPort), Visor's server's port") }
        return what.joined(separator: ", and ") + ". Quit Visor (its menu, Quit Visor), stop its server agent "
            + "(launchctl bootout gui/$(id -u)/com.LoganShire.Visor.server) and its agents' hosts first: docs/volume-conversion.md."
    }

    /// The refusal for files open on a volume, or nil when none is.
    public static func openFilesRefusal(mountPoint: String, holders: [String]) -> String? {
        guard !holders.isEmpty else { return nil }
        return "\(mountPoint) has files open by \(holders.joined(separator: ", ")) (sudo lsof \(mountPoint)): quit or stop them, "
            + "and try again once lsof lists nothing but Spotlight's and the system's own folders'."
    }
}
