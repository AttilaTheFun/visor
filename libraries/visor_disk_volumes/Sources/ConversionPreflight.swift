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

    /// The processes with a file open in `lsof <mount point>`'s output,
    /// Spotlight's aside: "<command> (<pid>)", each once, in order.
    public static func holders(lsof output: String) -> [String] {
        var seen: [String] = []
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 2, columns[0] != "COMMAND", !isSpotlight(String(columns[0])) else { continue }
            let holder = "\(columns[0]) (\(columns[1]))"
            if !seen.contains(holder) { seen.append(holder) }
        }
        return seen
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
        return "\(mountPoint) has files open by \(holders.joined(separator: ", ")) (lsof \(mountPoint)): quit or stop them, "
            + "and try again once lsof lists nothing but Spotlight's."
    }
}
