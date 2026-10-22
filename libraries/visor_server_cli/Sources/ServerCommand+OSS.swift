// The oss server (OS Server) sessions' agents may run in containers on:
// its address and token, the image its containers are made from, and how
// an agent in one reaches this server. oss hosts the containers; the
// server drives them.

import Foundation
import VisorServer

extension ServerCommand {
    /// Shows the oss server; `oss <url> <token file>` sets it and keeps
    /// its token, `oss -` takes it off, `oss image <name>|-` and `oss
    /// callback <ws-url>|-` set the rest.
    @MainActor
    func oss(_ arguments: [String]) throws {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        let platform = quietPlatform()
        switch arguments.first {
        case nil:
            print(Self.ossWords(settings, tokenKept: !(platform.secrets.get("ossToken") ?? "").isEmpty))
            return
        case "-":
            settings.ossServer = ""
            platform.secrets.set("ossToken", nil)
        case "image":
            guard arguments.count == 2 else { throw CommandLineError.usage("oss image <name>|-") }
            settings.ossImage = arguments[1] == "-" ? "" : arguments[1]
        case "callback":
            guard arguments.count == 2 else { throw CommandLineError.usage("oss callback <ws://host:port>|-") }
            settings.ossCallback = arguments[1] == "-" ? "" : arguments[1]
        case let server?:
            guard arguments.count == 2 else { throw CommandLineError.usage("oss <url> <token file>") }
            try ossToken(arguments[1])
            settings.ossServer = server
        }
        settings.keep(at: VisorServer.settingsURL)
        print(Self.ossWords(settings, tokenKept: !(platform.secrets.get("ossToken") ?? "").isEmpty) + " From the server's next start.")
    }

    /// `--oss-token-file <path>`, given with a run: the token kept as `oss`
    /// keeps it.
    @MainActor
    func ossToken(_ path: String) throws {
        let file = (path as NSString).expandingTildeInPath
        guard let token = try? String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw CommandLineError.failed("\(file) holds no token")
        }
        quietPlatform().secrets.set("ossToken", token)
    }

    /// `--oss <url>`, `--oss-image <name>`, given with a run.
    @MainActor
    func ossOption(_ name: String, _ value: String) {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        if name == "oss" { settings.ossServer = value == "-" ? "" : value } else { settings.ossImage = value == "-" ? "" : value }
        settings.keep(at: VisorServer.settingsURL)
    }

    static func ossWords(_ settings: ServerSettings, tokenKept: Bool) -> String {
        guard !settings.ossServer.isEmpty else { return "Containers: none (`oss <url> <token file>` runs sessions' agents in containers on an oss server)." }
        return "Containers: on oss at \(settings.ossServer)" + (tokenKept ? "" : ", with no token kept (`oss <url> <token file>`)")
            + ", from the image " + (settings.ossImage.isEmpty ? VisorServer.containerImage : settings.ossImage)
            + (settings.ossCallback.isEmpty ? "." : "; they reach this server at \(settings.ossCallback).")
    }
}
