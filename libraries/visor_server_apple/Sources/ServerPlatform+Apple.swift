import Foundation
import os
import VisorServer
import VisorServerPOSIX
import VisorServerSSH

extension ServerPlatform {
    /// A Mac's, for the menu bar app (and the staging server): the Network
    /// framework's sockets, POSIX terminals and signals, the keychain,
    /// CryptoKit and URLSession for pushes, ImageIO, the kernel's word on
    /// files, and the system log.
    public static func apple(secrets: any SecretStore = KeychainSecrets()) -> ServerPlatform {
        let logger = Logger(subsystem: "com.LoganShire.Visor", category: "server")
        let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Visor")
        return ServerPlatform(
            listening: NetworkListening(),
            terminals: POSIXTerminals(),
            processes: POSIXProcessSignals(),
            secrets: secrets,
            fetching: URLSessionFetching(),
            pushSigning: CryptoKitPushSigning(),
            images: ImageIOMeasuring(),
            files: DispatchFileWatching(),
            tools: MacTools(),
            host: HostDetails(name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName, dataDirectory: data,
                              addresses: { NetworkAddresses.all().map(\.address) },
                              networkAddresses: { NetworkAddresses.all().map { NetworkAddress(address: $0.address, interface: $0.name) } }),
            lifecycle: AppRelauncher(),
            log: { line in logger.info("\(line, privacy: .public)") },
            ssh: ConnectorPeerSSH()
        )
    }
}
