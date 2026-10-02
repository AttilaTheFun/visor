"""How this repository's Swift is compiled."""

# The Swift 6 language mode, where the compiler checks data-race safety, and
# warnings as errors. Every Swift target here passes these as its `copts`.
# They hold for an Apple build; a host that builds the client against its
# own SwiftUI (//:swift_ui) compiles it by its own rules.
STRICT_SWIFT = select({
    "//tools/swift:system_swift_ui": [
        "-swift-version",
        "6",
        "-warnings-as-errors",
    ],
    "//conditions:default": [],
})
