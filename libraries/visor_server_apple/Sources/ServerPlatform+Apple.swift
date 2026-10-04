import Foundation
import os
import VisorServer
import VisorServerPOSIX

extension ServerPlatform {
    /// A Mac's, for the menu bar app (and the staging server): the Network
    /// framework's sockets, POSIX terminals and signals, the keychain,
    /// CryptoKit and URLSession for pushes, ImageIO, the kernel's word on
    /// files, Tailscale's app, and the system log.
    public static func apple(secrets: any SecretStore = KeychainSecrets()) -> ServerPlatform {
        let logger = Logger(subsystem: "com.LoganShire.Visor", category: "server")
        let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Visor")
        return ServerPlatform(
            listening: NetworkLoopback(),
            terminals: POSIXTerminals(),
            processes: POSIXProcessSignals(),
            secrets: secrets,
            fetching: URLSessionFetching(),
            pushSigning: CryptoKitPushSigning(),
            images: ImageIOMeasuring(),
            files: DispatchFileWatching(),
            tools: MacTools(),
            host: HostDetails(name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName, dataDirectory: data),
            lifecycle: AppRelauncher(),
            exposure: { TailscaleExposure(cli: "/Applications/Tailscale.app/Contents/MacOS/Tailscale") },
            log: { line in logger.info("\(line, privacy: .public)") }
        )
    }
}
