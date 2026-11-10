// This device's own choices, from Settings: how the app looks, and which
// notifications it wants. Kept in the host's settings (UserDefaults on
// Apple, localStorage on the web). Each computer is told which kinds this
// device has muted when it registers for pushes, and again when they change;
// the notifications the device makes itself (for a computer that sends no
// pushes) follow the same choice.

import Observation
import VisorProtocol
import VisorServices

@MainActor
@Observable
public final class VisorPreferences {
    public static let shared = VisorPreferences()

    /// How the app looks.
    public var appearance: VisorAppearance {
        didSet { VisorHost.settings?.set(key: Self.appearanceKey, value: appearance.rawValue) }
    }
    /// The kinds of notification this device doesn't want, from any computer.
    public private(set) var muted: Set<PushKind>
    /// Told when `muted` changes: the store tells each computer again.
    @ObservationIgnored var onMutedChange: (() -> Void)?

    static let appearanceKey = "appearance"
    static let mutedKey = "notifications.muted"

    init() {
        let settings = VisorHost.settings
        appearance = VisorAppearance(rawValue: settings?.get(key: Self.appearanceKey) ?? "") ?? .system
        muted = Self.kinds(settings?.get(key: Self.mutedKey) ?? "")
    }

    /// Whether this device wants notifications of this kind.
    public func notifies(_ kind: PushKind) -> Bool { !muted.contains(kind) }

    /// Turns notifications of this kind on or off, and tells the computers.
    public func setNotifies(_ kind: PushKind, _ on: Bool) {
        guard notifies(kind) != on else { return }
        if on { muted.remove(kind) } else { muted.insert(kind) }
        VisorHost.settings?.set(key: Self.mutedKey, value: mutedList.joined(separator: ","))
        onMutedChange?()
    }

    /// The muted kinds as `push`'s `pushMuted` says them, in a fixed order.
    var mutedList: [String] { PushKind.allCases.filter(muted.contains).map(\.rawValue) }

    /// The kinds a kept list names ("turn,goal"), any it doesn't know left out.
    static func kinds(_ list: String) -> Set<PushKind> {
        Set(list.split(separator: ",").compactMap { PushKind(rawValue: String($0)) })
    }
}
