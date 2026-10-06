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
        if settings.reachableFromNetwork {
            let addresses = platform.host.addresses()
            print("The network reaches it directly" + (addresses.isEmpty ? "." : ", at " + addresses.joined(separator: ", ") + "."))
        } else {
            print("Only this computer reaches it: a reverse proxy or a tunnel here is the road in (`network on` opens it to the network).")
        }
        if settings.publicAddress.isEmpty {
            print("Clients are told " + (Self.reachableAddress(platform, settings).map { "\($0)." } ?? "no address: `address <url>` sets one."))
        } else {
            print("Clients are told \(settings.publicAddress) (set by hand).")
        }
    }

    /// The address clients are told, as the server would make it.
    static func reachableAddress(_ platform: ServerPlatform, _ settings: ServerSettings, port: UInt16 = Envelope.defaultPort) -> String? {
        let set = settings.publicAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !set.isEmpty { return set }
        guard settings.reachableFromNetwork, let first = platform.host.addresses().first else { return nil }
        return "http://\(first):\(port)"
    }

    /// Opens the server to the network, or keeps it to this computer.
    @MainActor
    func network(_ value: String?) throws {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        switch value {
        case "on": settings.reachableFromNetwork = true
        case "off": settings.reachableFromNetwork = false
        default: throw CommandLineError.usage("network on, or network off")
        }
        settings.keep(at: VisorServer.settingsURL)
        print(settings.reachableFromNetwork ? "The network reaches the server directly, from its next start." : "Only this computer reaches the server, from its next start.")
    }

    /// Shows or sets the address clients are told.
    @MainActor
    func address(_ value: String?) {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        guard let value else {
            print(settings.publicAddress.isEmpty ? "No address is set: clients are told the server's own guess, if the network reaches it." : settings.publicAddress)
            return
        }
        settings.publicAddress = value == "-" ? "" : value
        settings.keep(at: VisorServer.settingsURL)
        print(settings.publicAddress.isEmpty ? "Address cleared." : "Clients will be told \(settings.publicAddress), from the server's next start.")
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
