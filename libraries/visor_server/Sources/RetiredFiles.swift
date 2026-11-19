// What MultiPass and the parts Visor has since removed left in its data
// folder, which nothing reads any more: moved aside (never deleted) into
// `<data>/retired-<date>/` at the server's start, and logged. Only these
// exact names, never anything else of the folder's:
//
//   runner.json, runner-secrets.json, runner-secrets.json.lock  the old Runner's (#409)
//   hosts.jsonl                    MultiPass's (not `hosts/`, the agents' hosts' folder)
//   github-proxy-ca.pem            the GitHub proxy's CA (#422)
//   containers/, container-tools/  sessions in containers of their own (#343)
//
// visor_mcp.js isn't among them: VisorMCP still writes and runs it where
// there is no agent host.

import Foundation

package enum RetiredFiles {
    /// The names, each at the top of the data folder.
    package static let names = ["runner.json", "runner-secrets.json", "runner-secrets.json.lock", "hosts.jsonl",
                                "github-proxy-ca.pem", "containers", "container-tools"]

    /// Those of `names` in `folder` moved into `folder/retired-<date>/`
    /// (made when there is one to move), and logged: the names moved. One
    /// whose place there is taken already is left where it is, and logged.
    /// Nothing there: nothing done, and no folder made.
    @discardableResult
    package static func moveAside(in folder: URL, on date: Date = Date(), files: FileManager = .default,
                                  log: (String) -> Void = { VisorServer.log($0) }) -> [String] {
        // attributesOfItem doesn't follow a link: a link of one of these
        // names is moved itself, as it is.
        let present = names.filter { (try? files.attributesOfItem(atPath: folder.appendingPathComponent($0).path)) != nil }
        guard !present.isEmpty else { return [] }
        let retired = folder.appendingPathComponent("retired-" + day(date), isDirectory: true)
        do {
            // This user's alone (0700): runner-secrets.json holds tokens, and
            // each file keeps its own mode when it is moved.
            try files.createDirectory(at: retired, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: retired.path)
        } catch {
            log("retired files: couldn't make \(retired.path): \(error); left where they are: \(present.joined(separator: ", "))")
            return []
        }
        var moved: [String] = []
        for name in present {
            let target = retired.appendingPathComponent(name)
            if (try? files.attributesOfItem(atPath: target.path)) != nil {
                log("retired files: \(name) left where it is: \(retired.lastPathComponent) has one already")
                continue
            }
            do {
                try files.moveItem(at: folder.appendingPathComponent(name), to: target)
                moved.append(name)
            } catch {
                log("retired files: \(name) left where it is: \(error)")
            }
        }
        if !moved.isEmpty {
            log("retired files: moved \(moved.joined(separator: ", ")) (MultiPass's and removed parts', which nothing reads) "
                + "into \(retired.path)")
        }
        return moved
    }

    /// `date`'s day, as the folder is named: 2026-11-19 (UTC).
    static func day(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }
}
