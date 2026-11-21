// "Forget this device" (a computer's settings, over SSH): this device's SSH
// key taken out of the computer's authorized keys, where Visor put it
// (its line tagged `visor:<device>`: VisorServer+SSHKeys).

import VisorServices

extension AgentServerConnection {
    /// This device's key forgotten on this computer.
    public func forgetDeviceKey() async throws {
        guard let key = VisorHost.ssh?.publicKey(), !key.isEmpty else { throw AgentServerError.message("This device has no SSH key") }
        try await server.forgetSSHKey(key)
    }
}
