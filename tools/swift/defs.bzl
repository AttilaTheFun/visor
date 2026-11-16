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

# What an app on Apple's SwiftUI (the iPhone and iPad app, the Mac's) adds
# to its deps for Isomer's driver (isomer's docs/driver_in_apps.md): the
# Isomer module, which links the accessibility driver, in a build with
# --config=drive (--@isomer//drive:headful) alone. Without it, nothing: a
# release build has none of Isomer's Apple module (its web view, map,
# bridge) nor the driver, which turns accessibility on with a private call
# and obeys whoever its launch names.
ISOMER_APPLE_DRIVER = select({
    "@isomer//drive:headful_on": ["@isomer//:isomer"],
    "//conditions:default": [],
})
