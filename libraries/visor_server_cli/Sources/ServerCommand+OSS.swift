// The oss servers (OS Server) sessions lease through this server — machines
// (VMs, simulators, emulators) from the nearest with room, containers from
// the one on this computer: their addresses and tokens. And the containers
// sessions' agents run in on this computer: the image they are made from,
// and how an agent in one reaches this server.

import Foundation
import VisorServer

extension ServerCommand {
    /// Shows the oss servers; `oss <url> <token file>` adds one and keeps
    /// its token, `oss - <url>` takes one off, `oss -` takes them all off.
    @MainActor
    func oss(_ arguments: [String]) throws {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        let secrets = quietPlatform().secrets
        switch (arguments.first, arguments.count) {
        case (nil, _):
            print(Self.ossWords(settings, secrets))
            return
        case ("-"?, 1):
            for server in settings.ossServers { secrets.set(VisorServer.ossTokenKey(server), nil) }
            secrets.set("ossToken", nil)
            settings.ossServers = []
        case ("-"?, 2):
            let server = VisorServer.ossAddress(arguments[1])
            settings.ossServers.removeAll { VisorServer.ossAddress($0) == server }
            secrets.set(VisorServer.ossTokenKey(server), nil)
        case (let server?, 2):
            let address = VisorServer.ossAddress(server)
            if !settings.ossServers.map(VisorServer.ossAddress).contains(address) { settings.ossServers.append(address) }
            try ossToken(arguments[1], server: address)
        default:
            throw CommandLineError.usage("oss [<url> <token file> | - [<url>]]")
        }
        settings.keep(at: VisorServer.settingsURL)
        print(Self.ossWords(settings, secrets) + " From the server's next start.")
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

    /// The token in the file at `path`, kept as `server`'s (the last added,
    /// for `--oss-token-file` given with a run).
    @MainActor
    func ossToken(_ path: String, server: String? = nil) throws {
        let file = (path as NSString).expandingTildeInPath
        guard let token = try? String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw CommandLineError.failed("\(file) holds no token")
        }
        guard let server = server ?? ServerSettings.kept(at: VisorServer.settingsURL).ossServers.last else {
            throw CommandLineError.failed("no oss server to keep the token for (--oss <url> first)")
        }
        quietPlatform().secrets.set(VisorServer.ossTokenKey(server), token)
    }

    /// `--oss <url>|-` (added, or all taken off), `--container-image <name>`,
    /// given with a run.
    @MainActor
    func ossOption(_ name: String, _ value: String) {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        let set = value == "-" ? "" : value
        if name == "oss" {
            let address = VisorServer.ossAddress(set)
            if address.isEmpty { settings.ossServers = [] }
            else if !settings.ossServers.map(VisorServer.ossAddress).contains(address) { settings.ossServers.append(address) }
        } else {
            settings.containerImage = set
        }
        settings.keep(at: VisorServer.settingsURL)
    }

    static func ossWords(_ settings: ServerSettings, _ secrets: any SecretStore) -> String {
        guard !settings.ossServers.isEmpty else { return "Machines: none (`oss <url> <token file>` lets sessions lease machines from an oss server)." }
        let servers = settings.ossServers.map { server -> String in
            let kept = !(secrets.get(VisorServer.ossTokenKey(server)) ?? "").isEmpty
            return server + (kept ? "" : " (no token kept: `oss <url> <token file>`)")
        }
        return "Machines and containers: leased from oss at " + servers.joined(separator: ", ") + ", the nearest with room first."
    }

    static func containerWords(_ settings: ServerSettings) -> String {
        let image = settings.containerImage.isEmpty ? "Visor's own (\(VisorServer.containerImageRepository), this version's)" : settings.containerImage
        let callback = settings.containerCallback.isEmpty ? "this computer's LAN address" : settings.containerCallback
        return "Containers: made from the image \(image); they reach this server at \(callback)."
    }
}
