// What the server is and how it is reached, asked without running it:
// `status`, `password`, `code`.

import Foundation
import VisorProtocol
import VisorServer

extension ServerCommand {
    /// Whether it is running, and where clients reach it.
    @MainActor
    func status() async {
        let platform = quietPlatform()
        if let pid = runningProcess(platform) {
            print("The server is running (process \(pid)).")
        } else {
            print("The server is not running.")
        }
        let settings = ServerSettings.kept(at: VisorServer.settingsURL)
        let addresses = platform.host.networkAddresses()
        for kind in [NetworkAddress.Kind.lan, .vpn] {
            let on = kind == .lan ? settings.lan : settings.vpn
            let own = addresses.filter { $0.kind == kind }.map { "http://\($0.address):\(Envelope.defaultPort)" }
            print("\(kind == .lan ? "LAN" : "VPN"): " + (on ? (own.isEmpty ? "on, no address of that kind now." : "on, at " + own.joined(separator: ", ") + ".") : "off (`\(kind.rawValue) on` opens it)."))
        }
        print(settings.sshEnabled
              ? "Clients through this computer's SSH reach it at \(VisorServer.socketPath) without a password."
              : "Clients through this computer's SSH reach the port, with the password (`ssh on` lets them in without).")
        print("Reverse proxy: " + (settings.proxyEnabled && !settings.publicAddress.isEmpty ? "on, at \(settings.publicAddress)." : "off (`address <url>` sets one)."))
        print("Clients are told " + (Self.reachableAddress(platform, settings).map { "\($0)." } ?? "no address: only this computer and SSH reach the server."))
    }

    /// The address clients are told, as the server would make it.
    static func reachableAddress(_ platform: ServerPlatform, _ settings: ServerSettings, port: UInt16 = Envelope.defaultPort) -> String? {
        let set = settings.publicAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.proxyEnabled, !set.isEmpty { return set }
        let addresses = platform.host.networkAddresses()
        let open = addresses.filter { $0.kind == .vpn && settings.vpn } + addresses.filter { $0.kind == .lan && settings.lan }
        return open.first.map { "http://\($0.address):\(port)" }
    }

    /// Opens the server to the LAN and a VPN both, or keeps it to this computer.
    @MainActor
    func network(_ value: String?) throws {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        switch value {
        case "on": settings.lan = true; settings.vpn = true
        case "off": settings.lan = false; settings.vpn = false
        default: throw CommandLineError.usage("network on, or network off")
        }
        settings.keep(at: VisorServer.settingsURL)
        print(settings.reachableFromNetwork ? "The LAN and a VPN reach the server directly, from its next start." : "Only this computer reaches the server's port, from its next start.")
    }

    /// Opens one network path, or closes it.
    @MainActor
    func path(_ kind: NetworkAddress.Kind, _ value: String?) throws {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        let on: Bool
        switch value {
        case "on": on = true
        case "off": on = false
        default: throw CommandLineError.usage("\(kind.rawValue) on, or \(kind.rawValue) off")
        }
        if kind == .lan { settings.lan = on } else { settings.vpn = on }
        settings.keep(at: VisorServer.settingsURL)
        print("\(kind == .lan ? "The LAN" : "A VPN") \(on ? "reaches" : "no longer reaches") the server's port, from its next start.")
    }

    /// Lets SSH clients in without a password, or not.
    @MainActor
    func ssh(_ value: String?) throws {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        switch value {
        case "on": settings.sshEnabled = true
        case "off": settings.sshEnabled = false
        default: throw CommandLineError.usage("ssh on, or ssh off")
        }
        settings.keep(at: VisorServer.settingsURL)
        print(settings.sshEnabled
              ? "Clients through this computer's SSH are let in without a password, from the server's next start."
              : "Clients through this computer's SSH need the password, from the server's next start.")
    }

    /// Asks clients for the password, or nothing.
    @MainActor
    func auth(_ value: String?) throws {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        switch value {
        case "password": settings.authentication = "password"
        case "none": settings.authentication = "none"
        default: throw CommandLineError.usage("auth password, or auth none")
        }
        settings.keep(at: VisorServer.settingsURL)
        print(settings.asksNothing
              ? "Anyone who reaches the server is let in, from its next start: keep it to network paths of your own."
              : "Clients show the password, from the server's next start.")
    }

    /// Makes the server stand alone, or not.
    @MainActor
    func standalone(_ value: String?) throws {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        switch value {
        case "on": settings.standalone = true
        case "off": settings.standalone = false
        default: throw CommandLineError.usage("standalone on, or standalone off")
        }
        settings.keep(at: VisorServer.settingsURL)
        print(settings.standalone
              ? "The server stands alone from its next start: reached only at the address each client added it at, its other addresses and its peers shared with no one."
              : "The server shares its addresses and its peers again, from its next start.")
    }

    /// Shows or sets the address clients are told.
    @MainActor
    func address(_ value: String?) {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        guard let value else {
            print(settings.publicAddress.isEmpty ? "No reverse proxy address is set." : settings.publicAddress + (settings.proxyEnabled ? "" : " (off)"))
            return
        }
        if value == "-" {
            settings.proxyEnabled = false
        } else {
            settings.publicAddress = value
            settings.proxyEnabled = true
        }
        settings.keep(at: VisorServer.settingsURL)
        print(settings.proxyEnabled ? "Clients will be told \(settings.publicAddress) first, from the server's next start." : "The reverse proxy path is off.")
    }

    /// Shows the password, making one if there is none; or sets it.
    func password(_ new: String?) {
        let platform = quietPlatform()
        let running = runningProcess(platform) != nil
        if let new {
            platform.secrets.set("password", new)
            print(running ? "Password set. The running server takes it when it is started again." : "Password set.")
            return
        }
        if let kept = platform.secrets.get("password"), !kept.isEmpty {
            print(kept)
            return
        }
        let made = Self.newPassword()
        platform.secrets.set("password", made)
        print(made)
    }

    /// The connection code: this computer's name, its address, the password.
    @MainActor
    func code() throws {
        let platform = quietPlatform()
        guard let password = platform.secrets.get("password"), !password.isEmpty else {
            throw CommandLineError.failed("there is no password yet: `visor-server password` makes one")
        }
        let settings = ServerSettings.kept(at: VisorServer.settingsURL)
        guard let address = Self.reachableAddress(platform, settings) else {
            throw CommandLineError.failed("no address to give: `network on` for the network to reach this computer, or `address <url>` for a front of your own")
        }
        Self.printCode(ConnectionCode(name: platform.host.name, host: address, password: password))
    }
}
