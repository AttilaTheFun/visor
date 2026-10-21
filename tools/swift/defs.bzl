"""How this repository's Swift is compiled."""

# The Swift 6 language mode, where the compiler checks data-race safety, and
# warnings as errors. Every Swift target here passes these as its `copts`.
# They hold for an Apple build against Apple's SwiftUI; a build against
# Isomer's (the web, Android, Linux, Windows, or a feature compiled against
# Isomer's frameworks: isomer's own labels) compiles it by Isomer's rules.
_STRICT = [
    "-swift-version",
    "6",
    "-warnings-as-errors",
]

STRICT_SWIFT = select({
    "@platforms//os:wasi": [],
    "@platforms//os:android": [],
    "@platforms//os:linux": [],
    "@platforms//os:windows": [],
    "@isomer//apple/compiled:feature_on": [],
    "//conditions:default": _STRICT,
})
