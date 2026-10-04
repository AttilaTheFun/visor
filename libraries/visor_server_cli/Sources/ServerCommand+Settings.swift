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
        let exposure = platform.exposure()
        guard exposure.installed else {
            print("\(exposure.title) is not installed: clients reach this computer through it.")
            return
        }
        if let address = await exposure.address() {
            print("This computer is \(address) on \(exposure.title).")
        } else {
            print("\(exposure.title) has not said where this computer is: is it up?")
        }
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
    func code() async throws {
        let platform = quietPlatform()
        guard let password = platform.secrets.get("password"), !password.isEmpty else {
            throw CommandLineError.failed("there is no password yet: `visor-server password` makes one")
        }
        let exposure = platform.exposure()
        guard exposure.installed else { throw CommandLineError.failed("\(exposure.title) is not installed") }
        guard let address = await exposure.address() else {
            throw CommandLineError.failed("\(exposure.title) has not said where this computer is: is it up?")
        }
        Self.printCode(ConnectionCode(name: platform.host.name, host: address, password: password), through: exposure.title)
    }
}
