import Foundation

/// The app's data folder while it is checked (~/Library/Application
/// Support/Visor, the server's sessions.json and settings.json): one of
/// the check's own, made fresh and removed after. Its settings ask nothing
/// (`"authentication": "none"`): a server with no password, as on a Mac
/// where Visor was never set up, doesn't listen, and with nothing asked it
/// listens on 127.0.0.1 alone (lan and vpn are off by default), so
/// /api/hello answers.
///
/// A data folder that isn't the check's (a Mac where Visor has been set
/// up) is never touched: the check refuses to run there.
struct AppData {
    static let marker = ".launch_check"

    let folder: URL

    static func prepare() throws -> AppData {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Visor", isDirectory: true)
        if files.fileExists(atPath: folder.path) {
            guard files.fileExists(atPath: folder.appendingPathComponent(marker).path) else {
                throw LaunchCheckError.setup("\(folder.path) is a Visor's own: the check runs where Visor was never set up (a CI Mac, a leased VM)")
            }
            // One a check before left (it was stopped before it could remove it).
            try? files.removeItem(at: folder)
        }
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent(marker))
            try Data(#"{"authentication":"none"}"#.utf8).write(to: folder.appendingPathComponent("settings.json"))
        } catch {
            throw LaunchCheckError.setup("\(folder.path) couldn't be made: \(error.localizedDescription)")
        }
        return AppData(folder: folder)
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}
