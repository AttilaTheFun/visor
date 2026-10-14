import Foundation
import os
import VisorServer
import VisorServerPOSIX

extension ServerPlatform {
    /// A Mac's, for the menu bar app (and the staging server): the Network
    /// framework's sockets, POSIX signals, the keychain,
    /// CryptoKit and URLSession for pushes, ImageIO, the kernel's word on
    /// files, the system log, and the agents' host from the bundle.
    /// The app's version and build, from its bundle ("0.31 (8)").
    static var bundleVersion: String {
        guard let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "" }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    public static func apple(secrets: any SecretStore = KeychainSecrets()) -> ServerPlatform {
        let logger = Logger(subsystem: "com.LoganShire.Visor", category: "server")
        let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Visor")
        return ServerPlatform(
            listening: NetworkListening(),
            processes: POSIXProcessSignals(),
            secrets: secrets,
            fetching: URLSessionFetching(),
            pushSigning: CryptoKitPushSigning(),
            images: ImageIOMeasuring(),
            files: DispatchFileWatching(),
            tools: MacTools(),
            host: HostDetails(name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName, version: bundleVersion, dataDirectory: data,
                              addresses: { NetworkAddresses.all().map(\.address) },
                              networkAddresses: { NetworkAddresses.all().map { NetworkAddress(address: $0.address, interface: $0.name) } }),
            lifecycle: AppRelauncher(),
            // In the app's bundle, beside its own program.
            agentHosts: POSIXAgentHosting(program: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/visor-agent-host", isDirectory: false).path),
            log: { line in logger.info("\(line, privacy: .public)") }
        )
    }
}
