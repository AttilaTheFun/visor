// Where Isomer's driver can't yet take a step FEATURE_MAP.md has, so a test
// records it as a known issue on that platform and goes no further: on the
// iPhone, Apple's accessibility (drive/apple/UIKitAccessibility.swift).
// Once the driver takes it, the test does and no known issue is recorded.
// (The gaps found before isomer#228 and #231 are gone: identifiers on
// wrapped controls, List rows, combined elements, toggles and SwiftUI's
// own elements on the iPhone; a bottom bar's titles; dismiss of SwiftUI's
// sheets and Quick Look; taps in a turned window.)

enum IsomerGap: String {
    /// On the iPhone, `longpress` (drive/apple/UIKitAccessibility.swift's
    /// `longPress`) isn't driven yet: a context menu's interaction presents
    /// only through UIKit's own SPI.
    case appleLongPress = "Isomer (iOS): longpress (a context menu) isn't driven yet"
}
