// The containers sessions' agents run in on this computer
// (docs/container-host.md): the container host that makes them, the image
// they are made from, and how an agent in one reaches this server.

import Foundation
import VisorServer

extension ServerCommand {
    /// Shows the containers' settings; `containers host <command…>|-`,
    /// `containers image <name>|-` and `containers callback <ws-url>|-` set
    /// them.
    @MainActor
    func containers(_ arguments: [String]) throws {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        switch arguments.first {
        case nil:
            print(Self.containerWords(settings))
            return
        case "host":
            guard arguments.count >= 2 else { throw CommandLineError.usage("containers host <command> [arguments…] | -") }
            settings.containerHost = arguments[1] == "-" ? [] : Array(arguments.dropFirst())
        case "image":
            guard arguments.count == 2 else { throw CommandLineError.usage("containers image <name>|-") }
            settings.containerImage = arguments[1] == "-" ? "" : arguments[1]
        case "callback":
            guard arguments.count == 2 else { throw CommandLineError.usage("containers callback <ws://host:port>|-") }
            settings.containerCallback = arguments[1] == "-" ? "" : arguments[1]
        default:
            throw CommandLineError.usage("containers [host <command…>|- | image <name>|- | callback <ws://host:port>|-]")
        }
        settings.keep(at: VisorServer.settingsURL)
        print(Self.containerWords(settings) + " From the server's next start.")
    }

    /// `--container-image <name>|-` and `--container-host <command>|-`,
    /// given with a run.
    @MainActor
    func containerOption(_ name: String, _ value: String) {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        let set = value == "-" ? "" : value
        if name == "container-host" {
            settings.containerHost = set.isEmpty ? [] : set.split(separator: " ").map(String.init)
        } else {
            settings.containerImage = set
        }
        settings.keep(at: VisorServer.settingsURL)
    }

    static func containerWords(_ settings: ServerSettings) -> String {
        let host = settings.containerHost.isEmpty
            ? "\(VisorServer.containerHostName) on the PATH, if it is (none, and sessions run on this computer only)"
            : settings.containerHost.joined(separator: " ")
        let image = settings.containerImage.isEmpty ? "Visor's own (\(VisorServer.containerImageRepository), this version's)" : settings.containerImage
        let callback = settings.containerCallback.isEmpty ? "this computer's LAN address" : settings.containerCallback
        return "Containers: made by \(host), from the image \(image); they reach this server at \(callback)."
    }
}
