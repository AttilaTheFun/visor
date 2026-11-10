/// How the app looks (Settings › Appearance): as the device does, or always
/// light or always dark.
public enum VisorAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// What Settings calls it.
    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
