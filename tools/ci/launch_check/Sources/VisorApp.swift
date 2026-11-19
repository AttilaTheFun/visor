import Foundation

/// The app under check: where it is, and what its Info.plist says of it.
struct VisorApp {
    let url: URL
    let bundleID: String
    /// Its CFBundleExecutable: the process's name, and its crash reports'
    /// (`<executable>-<date>.ips`).
    let executable: String
    let version: String

    /// The app at `path`, or the one at the top of the .zip at `path`,
    /// unpacked into `work` with `ditto` as Finder would. Either is cleared
    /// of the quarantine a download gives it, so Gatekeeper's first-open
    /// dialog never waits on a click that no one makes.
    static func prepare(_ path: String, in work: URL) throws -> VisorApp {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else {
            throw LaunchCheckError.setup("no such file: \(path)")
        }
        let url: URL
        if isFolder.boolValue, path.hasSuffix(".app") {
            url = URL(fileURLWithPath: path)
        } else if path.hasSuffix(".zip") {
            let unpacked = work.appendingPathComponent("unpacked")
            let ditto = try Program.run("/usr/bin/ditto", ["-x", "-k", path, unpacked.path])
            guard ditto.succeeded else { throw LaunchCheckError.setup("ditto couldn't unpack \(path): \(ditto.output)") }
            let apps = (try? FileManager.default.contentsOfDirectory(atPath: unpacked.path))?.filter { $0.hasSuffix(".app") } ?? []
            guard apps.count == 1 else { throw LaunchCheckError.setup("\(path) holds \(apps.count) apps at its top, not one") }
            url = unpacked.appendingPathComponent(apps[0])
        } else {
            throw LaunchCheckError.usage("\(path) is neither a .app nor a .zip\n\(Options.usage)")
        }
        // No quarantine is no error: a build CI made never had one.
        _ = try Program.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path])

        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String,
              let executable = info["CFBundleExecutable"] as? String else {
            throw LaunchCheckError.setup("\(url.lastPathComponent) has no Info.plist naming its bundle id and executable")
        }
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        return VisorApp(url: url, bundleID: bundleID, executable: executable, version: version)
    }
}
