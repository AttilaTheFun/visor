// The client's services (visor's libraries/visor_services) as swift_ffi
// interfaces: what a browser or an Android host implements and injects.
// The shapes are the client's own, one for one; the adapters below hand
// the injected bridges to the client as its plain protocols.

import IsomerFFI
import VisorServices

/// The keys of the host-injected dependency dictionary.
@ExportedEnum
public enum BridgeKey: String {
    case socket
    case http
    case settings
    case dictation
    case network
}

/// A WebSocket per connection, by id. `next` suspends until the socket has
/// an event and returns it as one line: "open", "message <text>",
/// "close <reason>" or "error <reason>"; it throws once the socket is gone.
@ExportedInterface(namespace: "visor")
public protocol SocketBridge {
    func open(url: String) -> Int32
    func send(id: Int32, text: String)
    func disconnect(id: Int32)
    func next(id: Int32) async throws -> String
    func delay(milliseconds: Int32) async
}

/// One HTTP request: the answer's body, or a throw for a failed status.
@ExportedInterface(namespace: "visor")
public protocol HttpBridge {
    func request(method: String, url: String, body: String, authorization: String) async throws -> String
}

/// The saved computers and caches, as strings by key.
@ExportedInterface(namespace: "visor")
public protocol SettingsBridge {
    func get(key: String) -> String
    func set(key: String, value: String)
}

/// Speech to text, where the host has it (the composer's microphone).
/// `start` listens, or throws when refused (no permission, no microphone);
/// `next` suspends until more is heard and returns everything heard since
/// the start, and throws once listening has stopped; `stop` stops it.
@ExportedInterface(namespace: "visor")
public protocol DictationBridge {
    func start() async throws
    func next() async throws -> String
    func stop()
}

/// The device's networks, where the host can see them (a phone's; a
/// browser's cannot): `interfaces` is each IPv4 interface's address and
/// mask, loopback left out, one "address/mask" a line
/// ("192.168.1.20/255.255.255.0"); `changed` suspends until they change, and
/// throws once the host stops watching. Without it the client tries a
/// computer's paths in the record's order, a path that does not answer
/// costing a sign-in's timeout before the next.
@ExportedInterface(namespace: "visor")
public protocol NetworkBridge {
    func interfaces() -> String
    func changed() async throws
}

/// The client's dictation over the bridge: what is heard goes to `heard`
/// as it comes, until the bridge stops.
private final class DictationAdapter: VisorDictationService, @unchecked Sendable {
    let bridge: any DictationBridge
    private var listening: Task<Void, Never>?

    init(bridge: any DictationBridge) { self.bridge = bridge }

    func start(heard: @escaping @MainActor @Sendable (String) -> Void) async throws {
        stop()
        try await bridge.start()
        let bridge = bridge
        listening = Task { @MainActor in
            while !Task.isCancelled, let text = try? await bridge.next() {
                heard(text)
            }
        }
    }

    func stop() {
        listening?.cancel()
        listening = nil
        bridge.stop()
    }
}

private struct SocketAdapter: VisorSocketService {
    let bridge: any SocketBridge
    /// Whether the host's sockets die while the app is in the background (a
    /// phone's: iOS and Android suspend the app), so that the client opens
    /// every channel afresh on its return rather than waiting on dead ones:
    /// the host's `host.socketsDropInBackground` setting ("1").
    let dropsInBackground: Bool
    func open(url: String) -> Int32 { bridge.open(url: url) }
    func send(id: Int32, text: String) { bridge.send(id: id, text: text) }
    func disconnect(id: Int32) { bridge.disconnect(id: id) }
    func next(id: Int32) async throws -> String { try await bridge.next(id: id) }
    func delay(milliseconds: Int32) async { await bridge.delay(milliseconds: milliseconds) }
}

// The bridge is a host object (JavaScript, Kotlin) that is only ever used
// from the main thread the runtime runs on: Sendable by that, not by check.
private struct HTTPAdapter: VisorHTTPService, @unchecked Sendable {
    let bridge: any HttpBridge
    func request(method: String, url: String, body: String, authorization: String) async throws -> String {
        try await bridge.request(method: method, url: url, body: body, authorization: authorization)
    }
}

/// The client's network service over the bridge, as native Visor's
/// (NativeVisorNetworkService) answers from the interfaces the host reports:
/// whether a path's host is on one of the device's networks, whether it has
/// a tailnet's address, and a call when the networks change.
private final class NetworkAdapter: VisorNetworkService, @unchecked Sendable {
    let bridge: any NetworkBridge
    var onChange: (@MainActor () -> Void)?
    private var watching: Task<Void, Never>?

    init(bridge: any NetworkBridge) {
        self.bridge = bridge
        watching = Task { @MainActor [weak self, bridge] in
            while !Task.isCancelled, (try? await bridge.changed()) != nil {
                self?.onChange?()
            }
        }
    }

    func isOnLocalNetwork(_ host: String) -> Bool {
        guard let target = Self.ipv4(host) else { return false }
        return interfaces().contains { address, mask in mask != 0 && (address & mask) == (target & mask) }
    }

    var hasVPN: Bool {
        interfaces().contains { address, _ in (address & 0xFFC0_0000) == 0x6440_0000 }
    }

    private func interfaces() -> [(UInt32, UInt32)] {
        bridge.interfaces().split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "/")
            guard parts.count == 2, let address = Self.ipv4(parts[0]), let mask = Self.ipv4(parts[1]) else { return nil }
            return (address, mask)
        }
    }

    /// An IPv4 address as a number; nil for anything else.
    static func ipv4(_ text: some StringProtocol) -> UInt32? {
        let parts = text.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}

private struct SettingsAdapter: VisorSettingsService {
    let bridge: any SettingsBridge
    func get(key: String) -> String { bridge.get(key: key) }
    func set(key: String, value: String) { bridge.set(key: key, value: value) }
}

private func injected<T>(_ key: BridgeKey, as type: T.Type) -> T? {
    (dependencies[key] as? Lazy<T>)?.value ?? dependencies[key] as? T
}

/// Installs the host's bridges as the client's services. Call once, before
/// the store is made; a host that injected nothing leaves the client
/// without services, which it reports rather than crashes over.
public func installBridgedVisorServices() {
    guard let socket = injected(.socket, as: (any SocketBridge).self),
          let http = injected(.http, as: (any HttpBridge).self),
          let settings = injected(.settings, as: (any SettingsBridge).self)
    else { return }
    onHostMainActor {
        installVisorServices(socket: SocketAdapter(bridge: socket, dropsInBackground: settings.get(key: "host.socketsDropInBackground") == "1"), http: HTTPAdapter(bridge: http), settings: SettingsAdapter(bridge: settings),
                             deviceName: hostDeviceName(settings), appVersion: settings.get(key: "host.appVersion"),
                             platformName: settings.get(key: "host.platform"))
    }
    if let dictation = injected(.dictation, as: (any DictationBridge).self) {
        onHostMainActor { VisorHost.dictation = DictationAdapter(bridge: dictation) }
    }
    if let network = injected(.network, as: (any NetworkBridge).self) {
        onHostMainActor { VisorHost.network = NetworkAdapter(bridge: network) }
    }
}

/// The host hands its bridges over directly — what an Android host does
/// from Kotlin, through the generated `installVisorBridges`, before the
/// runtime starts.
@ExportedFunction(namespace: "visor")
public func installVisorBridges(socket: any SocketBridge, http: any HttpBridge, settings: any SettingsBridge) {
    onHostMainActor {
        installVisorServices(socket: SocketAdapter(bridge: socket, dropsInBackground: settings.get(key: "host.socketsDropInBackground") == "1"), http: HTTPAdapter(bridge: http), settings: SettingsAdapter(bridge: settings),
                             deviceName: hostDeviceName(settings), appVersion: settings.get(key: "host.appVersion"),
                             platformName: settings.get(key: "host.platform"))
    }
}

/// The device's networks, from a host that hands its bridges over directly
/// (Android's, through the generated `installVisorNetwork`), beside
/// `installVisorBridges` and before the runtime starts.
@ExportedFunction(namespace: "visor")
public func installVisorNetwork(network: any NetworkBridge) {
    onHostMainActor { VisorHost.network = NetworkAdapter(bridge: network) }
}

/// The system the host says it runs on (`host.platform`: "web",
/// "iOS (Isomer)"), from the settings it injected; "" from a host that
/// hands its bridges over directly (Android's) or injected none.
public func hostPlatform() -> String {
    injected(.settings, as: (any SettingsBridge).self)?.get(key: "host.platform") ?? ""
}

/// What the device is called, as its host names it (the settings key
/// `host.deviceName`: "Web" in a browser, the model on Android, the device's
/// name on iOS): how the servers it carries messages for name it to their
/// agents. Beside it the host says its own build (`host.appVersion`,
/// "0.31 (3)") and system (`host.platform`: "web", "Android",
/// "iOS (Isomer)"), which the client reports to those servers.
private func hostDeviceName(_ settings: any SettingsBridge) -> String {
    settings.get(key: "host.deviceName")
}

/// Runs `body` as the main actor. A host installs its services from its
/// start-up code — the page's script, the activity's onCreate, an `App`'s
/// init — which Isomer does not mark `@MainActor` but which runs on the
/// thread the main executor drains; visor's services are main-actor
/// isolated, so the call is made as that actor.
public func onHostMainActor(_ body: @MainActor () -> Void) {
    MainActor.assumeIsolated { body() }
}
