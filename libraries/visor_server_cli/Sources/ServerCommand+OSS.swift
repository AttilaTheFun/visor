// The oss server (OS Server) whose machines sessions lease through this
// server (VMs, simulators, emulators): its address and token. And the
// containers sessions' agents run in on this computer: the image they are
// made from, and how an agent in one reaches this server.

import Foundation
import VisorServer

extension ServerCommand {
    /// Shows the oss server; `oss <url> <token file>` sets it and keeps
    /// its token, `oss -` takes it off.
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
        case let server?:
            guard arguments.count == 2 else { throw CommandLineError.usage("oss <url> <token file>") }
            try ossToken(arguments[1])
            settings.ossServer = server
        }
        settings.keep(at: VisorServer.settingsURL)
        print(Self.ossWords(settings, tokenKept: !(platform.secrets.get("ossToken") ?? "").isEmpty) + " From the server's next start.")
    }

    /// Shows the containers' settings; `containers image <name>|-` and
    /// `containers callback <ws-url>|-` set them.
    @MainActor
    func containers(_ arguments: [String]) throws {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        switch arguments.first {
        case nil:
            print(Self.containerWords(settings))
            return
        case "image":
            guard arguments.count == 2 else { throw CommandLineError.usage("containers image <name>|-") }
            settings.containerImage = arguments[1] == "-" ? "" : arguments[1]
        case "callback":
            guard arguments.count == 2 else { throw CommandLineError.usage("containers callback <ws://host:port>|-") }
            settings.containerCallback = arguments[1] == "-" ? "" : arguments[1]
        default:
            throw CommandLineError.usage("containers [image <name>|- | callback <ws://host:port>|-]")
        }
        settings.keep(at: VisorServer.settingsURL)
        print(Self.containerWords(settings) + " From the server's next start.")
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

    /// `--oss <url>`, `--container-image <name>`, given with a run.
    @MainActor
    func ossOption(_ name: String, _ value: String) {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        let set = value == "-" ? "" : value
        if name == "oss" { settings.ossServer = set } else { settings.containerImage = set }
        settings.keep(at: VisorServer.settingsURL)
    }

    static func ossWords(_ settings: ServerSettings, tokenKept: Bool) -> String {
        guard !settings.ossServer.isEmpty else { return "Machines: none (`oss <url> <token file>` lets sessions lease machines from an oss server)." }
        let token = tokenKept ? "" : ", with no token kept (`oss <url> <token file>`)"
        return "Machines: leased from oss at \(settings.ossServer)\(token)."
    }

    static func containerWords(_ settings: ServerSettings) -> String {
        let image = settings.containerImage.isEmpty ? VisorServer.containerImage : settings.containerImage
        let callback = settings.containerCallback.isEmpty ? "this computer's LAN address" : settings.containerCallback
        return "Containers: made from the image \(image); they reach this server at \(callback)."
    }
}
