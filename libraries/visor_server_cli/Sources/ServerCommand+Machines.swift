// The virtual machines the server may run agents' sessions in: how many of
// each platform (none by default), and the script that provisions them.

import Foundation
import VisorProtocol
import VisorServer

extension ServerCommand {
    /// Shows the most machines of each platform; `machines <platform> <n>`
    /// sets one (0 takes it off).
    @MainActor
    func machines(_ arguments: [String]) throws {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        guard let name = arguments.first else {
            for platform in MachinePlatform.allCases {
                print("\(platform.title): \(Self.machineCount(settings.maxMachines(platform)))")
            }
            return
        }
        guard let platform = MachinePlatform(rawValue: name), arguments.count == 2, let count = Int(arguments[1]), count >= 0 else {
            throw CommandLineError.usage("machines <\(MachinePlatform.allCases.map(\.rawValue).joined(separator: "|"))> <count>")
        }
        settings.setMaxMachines(platform, count)
        settings.keep(at: VisorServer.settingsURL)
        let kept = settings.maxMachines(platform)
        let capped = kept < count ? " (\(platform.title) allows \(kept) per computer)" : ""
        print("\(platform.title): \(Self.machineCount(kept))\(capped), from the server's next start.")
    }

    /// `--machines macos=2,linux=4`, given with a run: each kept as
    /// `machines` keeps it.
    @MainActor
    func machinesOption(_ value: String) throws {
        for pair in value.split(separator: ",") {
            let parts = pair.split(separator: "=").map(String.init)
            guard parts.count == 2 else { throw CommandLineError.usage("--machines <platform>=<count>,…") }
            try machines(parts)
        }
    }

    /// Shows the provisioning script; `provisioning <path>` sets it,
    /// `provisioning -` goes back to Visor's own.
    @MainActor
    func provisioning(_ value: String?) throws {
        var settings = ServerSettings.kept(at: VisorServer.settingsURL)
        guard let value else {
            print(settings.provisioningScript.isEmpty ? "Visor's own provisioning script." : settings.provisioningScript)
            return
        }
        if value == "-" {
            settings.provisioningScript = ""
        } else {
            let path = (value as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: path) else { throw CommandLineError.failed("\(path) is not an executable file") }
            settings.provisioningScript = path
        }
        settings.keep(at: VisorServer.settingsURL)
        print(settings.provisioningScript.isEmpty
              ? "Machines are provisioned by Visor's own script, from the server's next start."
              : "Machines are provisioned by \(settings.provisioningScript), from the server's next start.")
    }

    static func machineCount(_ count: Int) -> String {
        count == 0 ? "none" : count == 1 ? "1 at a time" : "\(count) at a time"
    }
}
